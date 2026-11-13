//! The pieces of chat-shared.js that `launch-rivals.js` needs: `expandHome`
//! and `pathForms`. The Chat milestone (M3) ports the rest of that module and
//! extends this file.

use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use crate::paths::posix_join;

/// `~` and `~/…` name the home directory; any other value is kept as is.
pub fn expand_home(value: &str, home: &Path) -> PathBuf {
    if value == "~" {
        return home.to_path_buf();
    }
    match value.strip_prefix("~/") {
        Some(rest) => posix_join(&[home, Path::new(rest)]),
        None => PathBuf::from(value),
    }
}

/// `path.resolve(dir)`: absolute and normalized, against the working directory
/// when relative, without a trailing slash.
fn resolve(dir: &Path) -> PathBuf {
    let absolute = if dir.has_root() {
        posix_join(&[dir])
    } else {
        match std::env::current_dir() {
            Ok(cwd) => posix_join(&[&cwd, dir]),
            Err(_) => posix_join(&[dir]),
        }
    };
    let text = absolute.as_os_str().as_encoded_bytes();
    if text.len() > 1 && text.ends_with(b"/") {
        PathBuf::from(std::ffi::OsStr::from_bytes(&text[..text.len() - 1]))
    } else {
        absolute
    }
}

/// The forms one directory can be told by: its `path.resolve` and, while it
/// exists, its real path.
pub fn path_forms(dir: &Path) -> Vec<PathBuf> {
    let mut forms = vec![resolve(dir)];
    // A cwd that no longer exists still matches by its resolved form.
    if let Ok(real) = std::fs::canonicalize(dir)
        && !forms.contains(&real)
    {
        forms.push(real);
    }
    forms
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_is_expanded_only_as_a_leading_tilde_segment() {
        let home = Path::new("/home/u");
        assert_eq!(expand_home("~", home), Path::new("/home/u"));
        assert_eq!(
            expand_home("~/src//proj/", home),
            Path::new("/home/u/src/proj")
        );
        assert_eq!(expand_home("~/", home), Path::new("/home/u"));
        assert_eq!(expand_home("~other/x", home), Path::new("~other/x"));
        assert_eq!(expand_home("/a/../b", home), Path::new("/a/../b"));
    }

    #[test]
    fn a_directory_is_told_by_its_resolved_and_its_real_path() {
        let dir = std::env::temp_dir().join(format!("wc-forms-{}", std::process::id()));
        let real = dir.join("real");
        std::fs::create_dir_all(&real).unwrap();
        std::os::unix::fs::symlink(&real, dir.join("link")).unwrap();
        let canonical = std::fs::canonicalize(&real).unwrap();
        let forms = path_forms(&dir.join("link/../link/"));
        assert_eq!(forms[0], dir.join("link"));
        assert!(forms.contains(&canonical));
        // A missing directory has its resolved form only, and `..` collapses.
        assert_eq!(path_forms(&dir.join("gone/../gone2")), [dir.join("gone2")]);
        let relative = path_forms(Path::new("some/./dir"));
        assert_eq!(
            relative,
            [std::env::current_dir().unwrap().join("some/dir")]
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
