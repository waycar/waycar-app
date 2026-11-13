//! Node's `path` (posix) on strings. `std::path::Path::join` differs where
//! the ported modules can notice: an absolute segment replaces the base,
//! `..` and `.` are kept, and an empty segment is not skipped. Transcript
//! paths cross the JSON boundary as strings, so the ports keep strings and
//! use these.

use std::path::Path;

fn normalize_segments(path: &str, allow_above_root: bool) -> String {
    let mut out: Vec<&str> = Vec::new();
    for segment in path.split('/') {
        match segment {
            "" | "." => {}
            ".." => {
                if out.last().is_some_and(|last| *last != "..") {
                    out.pop();
                } else if allow_above_root {
                    out.push("..");
                }
            }
            other => out.push(other),
        }
    }
    out.join("/")
}

/// `path.normalize`.
pub fn normalize(path: &str) -> String {
    if path.is_empty() {
        return ".".into();
    }
    let absolute = path.starts_with('/');
    let trailing = path.ends_with('/');
    let mut body = normalize_segments(path, !absolute);
    if body.is_empty() {
        if absolute {
            return "/".into();
        }
        return if trailing { "./".into() } else { ".".into() };
    }
    if trailing {
        body.push('/');
    }
    if absolute { format!("/{body}") } else { body }
}

/// `path.join(...parts)`.
pub fn join(parts: &[&str]) -> String {
    let joined: Vec<&str> = parts.iter().copied().filter(|p| !p.is_empty()).collect();
    if joined.is_empty() {
        return ".".into();
    }
    normalize(&joined.join("/"))
}

/// `path.isAbsolute`.
pub fn is_absolute(path: &str) -> bool {
    path.starts_with('/')
}

/// `path.resolve(...parts)` against the process's working directory.
pub fn resolve(parts: &[&str]) -> String {
    let mut resolved = String::new();
    for part in parts.iter().rev() {
        if part.is_empty() {
            continue;
        }
        resolved = if resolved.is_empty() {
            (*part).to_string()
        } else {
            format!("{part}/{resolved}")
        };
        if part.starts_with('/') {
            break;
        }
    }
    if !resolved.starts_with('/') {
        let cwd = std::env::current_dir()
            .map(|dir| dir.to_string_lossy().into_owned())
            .unwrap_or_else(|_| "/".into());
        resolved = if resolved.is_empty() {
            cwd
        } else {
            format!("{cwd}/{resolved}")
        };
    }
    let body = normalize_segments(&resolved, false);
    format!("/{body}")
}

/// `path.basename(path)`.
pub fn basename(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    trimmed.rsplit('/').next().unwrap_or("")
}

/// `path.dirname(path)` (Node's scan, slash runs included).
pub fn dirname(path: &str) -> String {
    let bytes = path.as_bytes();
    if bytes.is_empty() {
        return ".".into();
    }
    let has_root = bytes[0] == b'/';
    let mut end = None;
    let mut matched_slash = true;
    for i in (1..bytes.len()).rev() {
        if bytes[i] == b'/' {
            if !matched_slash {
                end = Some(i);
                break;
            }
        } else {
            matched_slash = false;
        }
    }
    match end {
        None => {
            if has_root {
                "/".into()
            } else {
                ".".into()
            }
        }
        Some(1) if has_root => "//".into(),
        Some(end) => path[..end].to_string(),
    }
}

/// `path.relative(from, to)`.
pub fn relative(from: &str, to: &str) -> String {
    let from = resolve(&[from]);
    let to = resolve(&[to]);
    if from == to {
        return String::new();
    }
    let a: Vec<&str> = from.split('/').filter(|s| !s.is_empty()).collect();
    let b: Vec<&str> = to.split('/').filter(|s| !s.is_empty()).collect();
    let common = a.iter().zip(&b).take_while(|(x, y)| x == y).count();
    let mut out: Vec<&str> = vec![".."; a.len() - common];
    out.extend(&b[common..]);
    out.join("/")
}

/// A std path as the string JavaScript would hold (lossy where not UTF-8).
pub fn text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn join_and_normalize_follow_node() {
        assert_eq!(join(&["/a", "b", "../c"]), "/a/c");
        assert_eq!(join(&["a", "", "b/"]), "a/b/");
        assert_eq!(join(&["", ""]), ".");
        assert_eq!(join(&["/", ".."]), "/");
        assert_eq!(join(&["a", "../.."]), "..");
        assert_eq!(join(&["/a", "/b"]), "/a/b");
        assert_eq!(normalize(""), ".");
        assert_eq!(normalize("./"), "./");
        assert_eq!(normalize("//a//b/./c"), "/a/b/c");
    }

    #[test]
    fn resolve_basename_dirname_relative() {
        assert_eq!(resolve(&["/a", "b", "../c"]), "/a/c");
        assert_eq!(resolve(&["/a", "/b", "c/"]), "/b/c");
        assert_eq!(basename("/a/b.txt"), "b.txt");
        assert_eq!(basename("/a/b/"), "b");
        assert_eq!(basename("/"), "");
        assert_eq!(dirname("/a/b/"), "/a");
        assert_eq!(dirname("a"), ".");
        assert_eq!(dirname("/a"), "/");
        assert_eq!(dirname("/"), "/");
        assert_eq!(dirname("//"), "/");
        assert_eq!(dirname("//a"), "//");
        assert_eq!(dirname("a//b"), "a/");
        assert_eq!(dirname("a/b"), "a");
        assert_eq!(relative("/a/b", "/a/c/d"), "../c/d");
        assert_eq!(relative("/a", "/a"), "");
    }
}
