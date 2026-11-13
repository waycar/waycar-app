//! Reading and writing the hook files, with the errors worded as Node words
//! them (`EACCES: permission denied, open '<path>'`): the JS prints those
//! messages in the `error:` lines of `hooks install`.

use std::fs::{self, DirBuilder};
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use crate::atomic::{WriteStep, write_atomic_traced};
use crate::js_json::{Json, Obj, parse};
use crate::jsx;

/// libuv's name and text for an errno, as `uv_strerror` words them.
fn uv_error(errno: i32) -> (&'static str, &'static str) {
    match errno {
        libc::E2BIG => ("E2BIG", "argument list too long"),
        libc::EACCES => ("EACCES", "permission denied"),
        libc::EAGAIN => ("EAGAIN", "resource temporarily unavailable"),
        libc::EBADF => ("EBADF", "bad file descriptor"),
        libc::EBUSY => ("EBUSY", "resource busy or locked"),
        libc::ECANCELED => ("ECANCELED", "operation canceled"),
        libc::EEXIST => ("EEXIST", "file already exists"),
        libc::EFAULT => ("EFAULT", "bad address in system call argument"),
        libc::EFBIG => ("EFBIG", "file too large"),
        libc::EINTR => ("EINTR", "interrupted system call"),
        libc::EINVAL => ("EINVAL", "invalid argument"),
        libc::EIO => ("EIO", "i/o error"),
        libc::EISDIR => ("EISDIR", "illegal operation on a directory"),
        libc::ELOOP => ("ELOOP", "too many symbolic links encountered"),
        libc::EMFILE => ("EMFILE", "too many open files"),
        libc::ENAMETOOLONG => ("ENAMETOOLONG", "name too long"),
        libc::ENFILE => ("ENFILE", "file table overflow"),
        libc::ENODEV => ("ENODEV", "no such device"),
        libc::ENOENT => ("ENOENT", "no such file or directory"),
        libc::ENOMEM => ("ENOMEM", "not enough memory"),
        libc::ENOSPC => ("ENOSPC", "no space left on device"),
        libc::ENOTDIR => ("ENOTDIR", "not a directory"),
        libc::ENOTEMPTY => ("ENOTEMPTY", "directory not empty"),
        libc::ENXIO => ("ENXIO", "no such device or address"),
        libc::EOPNOTSUPP => ("ENOTSUP", "operation not supported on socket"),
        libc::EPERM => ("EPERM", "operation not permitted"),
        libc::EROFS => ("EROFS", "read-only file system"),
        libc::ETXTBSY => ("ETXTBSY", "text file is busy"),
        libc::EXDEV => ("EXDEV", "cross-device link not permitted"),
        _ => ("UNKNOWN", "unknown error"),
    }
}

/// An fs error the way Node words it: `CODE: text, syscall 'path'`, with
/// `-> 'dest'` for a rename; `path` is `None` for a syscall on an open file.
pub fn node_message(
    error: &io::Error,
    syscall: &str,
    path: Option<&Path>,
    dest: Option<&Path>,
) -> String {
    let (code, text) = uv_error(error.raw_os_error().unwrap_or(0));
    let mut message = format!("{code}: {text}, {syscall}");
    if let Some(path) = path {
        message.push_str(&format!(" '{}'", path.display()));
    }
    if let Some(dest) = dest {
        message.push_str(&format!(" -> '{}'", dest.display()));
    }
    message
}

/// `fs.readFileSync(path, "utf8")`; the error is Node's message.
pub fn read_required(path: &Path) -> Result<String, String> {
    match fs::read(path) {
        Ok(bytes) => Ok(String::from_utf8_lossy(&bytes).into_owned()),
        // open(2) of a directory succeeds; the read is what fails, and Node
        // names no path for it.
        Err(error) if error.raw_os_error() == Some(libc::EISDIR) => {
            Err(node_message(&error, "read", None, None))
        }
        Err(error) => Err(node_message(&error, "open", Some(path), None)),
    }
}

/// The file's text, or `None` when it does not exist (`readText`).
pub fn read_text(path: &Path) -> Result<Option<String>, String> {
    match fs::read(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        _ => read_required(path).map(Some),
    }
}

/// A hook file's top-level object, and whether the file exists (`readJsonObject`).
pub fn read_json_object(path: &Path) -> Result<(bool, Obj), String> {
    let text = read_text(path)?;
    let exists = text.is_some();
    let Some(text) = text.filter(|text| !jsx::trim(text).is_empty()) else {
        return Ok((exists, Obj::new()));
    };
    let shown = path.display();
    let value = parse(&text)
        .map_err(|message| format!("{shown} is not valid JSON ({message}); left unchanged"))?;
    let Json::Obj(object) = value else {
        return Err(format!(
            "{shown} does not hold a JSON object; left unchanged"
        ));
    };
    if object
        .get("hooks")
        .is_some_and(|hooks| !matches!(hooks, Json::Obj(_)))
    {
        return Err(format!(
            "{shown} has a \"hooks\" value that is not an object; left unchanged"
        ));
    }
    Ok((true, object))
}

/// Write `data` through a symlink, keeping the mode found; a new file gets
/// `new_mode` (before the umask) and its directories are created
/// (`writeFilePreservingMode`).
pub fn write_preserving_mode(path: &Path, data: &str, new_mode: u32) -> Result<(), String> {
    let (target, mode) = if path.exists() {
        let target = fs::canonicalize(path)
            .map_err(|error| node_message(&error, "stat", Some(path), None))?;
        let mode = fs::metadata(&target)
            .map_err(|error| node_message(&error, "stat", Some(&target), None))?
            .permissions()
            .mode()
            & 0o777;
        (target, mode)
    } else {
        let dir = path
            .parent()
            .filter(|dir| !dir.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        DirBuilder::new()
            .recursive(true)
            .create(dir)
            .map_err(|error| node_message(&error, "mkdir", Some(dir), None))?;
        (path.to_path_buf(), new_mode)
    };
    write_atomic_traced(&target, data.as_bytes(), mode).map_err(|failed| match failed.step {
        WriteStep::Open => node_message(&failed.source, "open", Some(&failed.temp), None),
        WriteStep::Write => node_message(&failed.source, "write", None, None),
        WriteStep::Rename => {
            node_message(&failed.source, "rename", Some(&failed.temp), Some(&target))
        }
    })
}

/// `JSON.stringify(value, null, 2)` plus a newline, written with
/// [`write_preserving_mode`].
pub fn write_json(path: &Path, value: &Json, new_mode: u32) -> Result<(), String> {
    write_preserving_mode(path, &format!("{}\n", value.to_pretty()), new_mode)
}

/// `fs.rmSync(path, { force: true })`: a missing file is fine. Node 22 and
/// later word the other failures as `CODE, strerror: 'path'`.
pub fn remove_file(path: &Path) -> Result<(), String> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => {
            let errno = error.raw_os_error().unwrap_or(0);
            if errno == libc::EISDIR {
                return Err(format!(
                    "Path is a directory: rm returned EISDIR (is a directory) {}",
                    path.display()
                ));
            }
            let text = error.to_string();
            let text = text.split(" (os error").next().unwrap_or(&text);
            Err(format!(
                "{}, {text}: '{}'",
                uv_error(errno).0,
                path.display()
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::symlink;

    use super::*;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("wc-hooks-files-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn os_errors_read_as_node_words_them() {
        let dir = scratch("errors");
        fs::write(dir.join("file"), "x").unwrap();
        fs::create_dir(dir.join("sub")).unwrap();
        symlink("loop", dir.join("loop")).unwrap();
        let path = |name: &str| dir.join(name);
        assert_eq!(read_text(&path("missing")).unwrap(), None);
        assert_eq!(
            read_text(&path("sub")).unwrap_err(),
            "EISDIR: illegal operation on a directory, read"
        );
        assert_eq!(
            read_text(&path("file/x")).unwrap_err(),
            format!(
                "ENOTDIR: not a directory, open '{}'",
                path("file/x").display()
            )
        );
        assert_eq!(
            read_text(&path("loop")).unwrap_err(),
            format!(
                "ELOOP: too many symbolic links encountered, open '{}'",
                path("loop").display()
            )
        );
        assert!(
            read_required(&path("missing"))
                .unwrap_err()
                .starts_with("ENOENT: no such file or directory, open '")
        );
        // mkdir -p through a file, and onto one.
        assert_eq!(
            write_preserving_mode(&path("file/a/config.json"), "{}", 0o644).unwrap_err(),
            format!(
                "ENOTDIR: not a directory, mkdir '{}'",
                path("file/a").display()
            )
        );
        // mkdir -p onto a file is EEXIST, not ENOTDIR.
        assert_eq!(
            write_preserving_mode(&path("file/x"), "{}", 0o644).unwrap_err(),
            format!(
                "EEXIST: file already exists, mkdir '{}'",
                path("file").display()
            )
        );
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn permission_errors_name_the_failing_step() {
        if unsafe { libc::geteuid() } == 0 {
            return; // root passes every permission check
        }
        let dir = scratch("perm");
        let locked = dir.join("locked");
        fs::create_dir(&locked).unwrap();
        fs::write(locked.join("inner"), "x").unwrap();
        fs::write(dir.join("unreadable"), "x").unwrap();
        fs::set_permissions(dir.join("unreadable"), fs::Permissions::from_mode(0o000)).unwrap();
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o555)).unwrap();
        assert_eq!(
            read_text(&dir.join("unreadable")).unwrap_err(),
            format!(
                "EACCES: permission denied, open '{}'",
                dir.join("unreadable").display()
            )
        );
        let target = locked.join("new.json");
        let temp = format!("{}.tmp-{}", target.display(), std::process::id());
        assert_eq!(
            write_preserving_mode(&target, "{}", 0o644).unwrap_err(),
            format!("EACCES: permission denied, open '{temp}'")
        );
        assert_eq!(
            write_preserving_mode(&locked.join("a/b/c.json"), "{}", 0o644).unwrap_err(),
            format!(
                "EACCES: permission denied, mkdir '{}'",
                locked.join("a/b").display()
            )
        );
        assert_eq!(
            remove_file(&locked.join("inner")).unwrap_err(),
            format!(
                "EACCES, Permission denied: '{}'",
                locked.join("inner").display()
            )
        );
        // The old file stays when the directory refuses the temp file.
        let existing = locked.join("inner");
        let err = write_preserving_mode(&existing, "{}", 0o644).unwrap_err();
        assert!(
            err.starts_with("EACCES: permission denied, open '"),
            "{err}"
        );
        assert_eq!(fs::read_to_string(&existing).unwrap(), "x");
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn json_objects_are_checked_before_anything_is_written() {
        let dir = scratch("objects");
        let path = dir.join("settings.json");
        let shown = path.display();
        let read = |text: &str| {
            fs::write(&path, text).unwrap();
            read_json_object(&path)
        };
        assert!(read_json_object(&path).unwrap().1.is_empty());
        assert!(!read_json_object(&path).unwrap().0);
        assert_eq!(read("  \n").map(|(exists, _)| exists), Ok(true));
        assert_eq!(
            read("{ not json").unwrap_err(),
            format!(
                "{shown} is not valid JSON (Expected property name or '}}' in JSON at position 2 (line 1 column 3)); left unchanged"
            )
        );
        for body in ["[]", "null", "3", "\"x\""] {
            assert_eq!(
                read(body).unwrap_err(),
                format!("{shown} does not hold a JSON object; left unchanged"),
                "{body}"
            );
        }
        for body in [r#"{"hooks":[]}"#, r#"{"hooks":null}"#] {
            assert_eq!(
                read(body).unwrap_err(),
                format!("{shown} has a \"hooks\" value that is not an object; left unchanged"),
                "{body}"
            );
        }
        assert!(read(r#"{"hooks":{}}"#).is_ok());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn writes_go_through_symlinks_and_keep_the_mode() {
        let dir = scratch("modes");
        let real = dir.join("dotfiles/settings.json");
        fs::create_dir_all(real.parent().unwrap()).unwrap();
        fs::write(&real, "old").unwrap();
        fs::set_permissions(&real, fs::Permissions::from_mode(0o600)).unwrap();
        let link = dir.join("link.json");
        symlink(&real, &link).unwrap();
        write_preserving_mode(&link, "new", 0o644).unwrap();
        assert!(
            fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(fs::read_to_string(&real).unwrap(), "new");
        assert_eq!(
            fs::metadata(&real).unwrap().permissions().mode() & 0o777,
            0o600
        );
        // A new file gets the requested mode (umask permitting) and its directory.
        let fresh = dir.join("a/b/new.json");
        write_preserving_mode(&fresh, "x", 0o600).unwrap();
        assert_eq!(
            fs::metadata(&fresh).unwrap().permissions().mode() & 0o777,
            0o600
        );
        // A dangling symlink counts as missing and is replaced.
        let dangling = dir.join("dangling.json");
        symlink(dir.join("nowhere"), &dangling).unwrap();
        write_preserving_mode(&dangling, "y", 0o644).unwrap();
        assert!(
            !fs::symlink_metadata(&dangling)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        remove_file(&dir.join("absent")).unwrap();
        fs::remove_dir_all(&dir).unwrap();
    }
}
