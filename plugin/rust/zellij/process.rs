//! Lossless process argv/environment for Zellij ownership and resurrection.
//! macOS KERN_PROCARGS2 and Linux /proc delimit strings with NUL, so spaces
//! and additional '=' characters in an environment value are not syntax.
use crate::env::Env;

pub(super) struct Process {
    pub argv: Vec<String>,
    pub env: Env,
}

#[cfg(target_os = "linux")]
pub(super) fn read(pid: u32, env: &Env) -> Option<Process> {
    let root = env.non_empty("WAYCAR_HOOK_PROC").unwrap_or("/proc");
    let path = std::path::Path::new(root).join(pid.to_string());
    let argv = std::fs::read(path.join("cmdline")).ok()?;
    let environ = std::fs::read(path.join("environ")).ok()?;
    let argv = argv
        .strip_suffix(&[0])
        .unwrap_or(&argv)
        .split(|b| *b == 0)
        .map(|s| String::from_utf8_lossy(s).into_owned())
        .collect();
    Some(Process {
        argv,
        env: environment(&environ),
    })
}

#[cfg(target_os = "macos")]
pub(super) fn read(pid: u32, _env: &Env) -> Option<Process> {
    let mut argmax: libc::c_int = 0;
    let mut size = std::mem::size_of_val(&argmax);
    let mut mib = [libc::CTL_KERN, libc::KERN_ARGMAX];
    // SAFETY: both MIBs and output buffers are allocated at the stated sizes;
    // sysctl only reads the MIB and writes up to the supplied output length.
    let result = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as u32,
            (&mut argmax as *mut libc::c_int).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if result != 0 || argmax <= 0 {
        return None;
    }
    let mut bytes = vec![0u8; argmax as usize];
    size = bytes.len();
    let mut mib = [
        libc::CTL_KERN,
        libc::KERN_PROCARGS2,
        libc::c_int::try_from(pid).ok()?,
    ];
    // SAFETY: bytes is writable for size bytes and mib has mib.len() entries.
    let result = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as u32,
            bytes.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if result != 0 {
        return None;
    }
    bytes.truncate(size);
    parse_procargs2(&bytes)
}

fn environment(bytes: &[u8]) -> Env {
    let mut env = Env::default();
    for entry in bytes
        .split(|b| *b == 0)
        .take_while(|entry| !entry.is_empty())
    {
        if let Some((key, value)) = String::from_utf8_lossy(entry).split_once('=') {
            env.set(key, value);
        }
    }
    env
}

/// Native argc, executable path, padding, argc argv strings, then env strings.
#[cfg(any(target_os = "macos", test))]
pub(super) fn parse_procargs2(bytes: &[u8]) -> Option<Process> {
    let (argc, mut rest) = bytes.split_at_checked(std::mem::size_of::<libc::c_int>())?;
    let argc = libc::c_int::from_ne_bytes(argc.try_into().ok()?);
    if argc <= 0 {
        return None;
    }
    rest = rest
        .split_at_checked(rest.iter().position(|b| *b == 0)? + 1)?
        .1;
    rest = &rest[rest.iter().take_while(|b| **b == 0).count()..];
    let mut argv = Vec::new();
    for _ in 0..argc {
        let end = rest.iter().position(|b| *b == 0)?;
        argv.push(String::from_utf8_lossy(&rest[..end]).into_owned());
        rest = &rest[end + 1..];
    }
    Some(Process {
        argv,
        env: environment(rest),
    })
}
