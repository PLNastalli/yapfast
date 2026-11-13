//! Native Windows WireSock launcher for an opt-in media-only Go Live tunnel.
//! The normal Yapfast UI remains unelevated. Only this executable's helper
//! process is elevated to manage WireSock's packet filter.
#![cfg(windows)]

use std::{
    ffi::{OsStr, OsString},
    fs::{self, File},
    io,
    os::windows::{ffi::OsStrExt, process::CommandExt},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Arc, atomic::{AtomicBool, Ordering}},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use windows_sys::Win32::{
    Foundation::{CloseHandle, HANDLE, WAIT_TIMEOUT},
    System::Threading::{OpenProcess, WaitForSingleObject},
    UI::{
        Shell::{SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW, ShellExecuteExW},
        WindowsAndMessaging::{MB_ICONERROR, MB_OK, MessageBoxW, SW_HIDE},
    },
};

const SETTINGS_FILE: &str = "golive-vpn.json";
const HELPER_ARG: &str = "--golive-vpn-helper";
const NO_WINDOW: u32 = 0x0800_0000;

#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
struct Settings {
    enabled: bool,
    profile: Option<PathBuf>,
}

impl Settings {
    fn read(root: &Path) -> Self {
        fs::read(root.join(SETTINGS_FILE))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn write(&self, root: &Path) -> Result<()> {
        fs::create_dir_all(root).context("could not create Yapfast's settings folder")?;
        let temporary = root.join("golive-vpn.json.tmp");
        fs::write(&temporary, serde_json::to_vec_pretty(self)?)?;
        fs::rename(&temporary, root.join(SETTINGS_FILE))
            .context("could not save Go Live settings")?;
        Ok(())
    }

    fn profile(&self) -> PathBuf {
        self.profile.clone().unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("USERPROFILE").unwrap_or_default())
                .join(r"Downloads\YapFast-GoLive\vpn.conf")
        })
    }
}

/// Called by Settings > Advanced; the choice takes effect on restart.
pub(crate) fn enabled(root: &Path) -> bool {
    Settings::read(root).enabled
}

pub(crate) fn profile_display(root: &Path) -> String {
    Settings::read(root).profile().display().to_string()
}

pub(crate) fn set_enabled(root: &Path, enabled: bool) -> Result<()> {
    let mut settings = Settings::read(root);
    settings.enabled = enabled;
    settings.write(root)
}

pub(crate) fn set_profile(root: &Path, path: &Path) -> Result<()> {
    if path.extension().is_none_or(|ext| !ext.eq_ignore_ascii_case("conf")) {
        bail!("select a WireGuard .conf file");
    }
    if !path.is_file() {
        bail!("WireGuard profile not found: {}", path.display());
    }
    let mut settings = Settings::read(root);
    settings.profile = Some(path.canonicalize()?);
    settings.write(root)
}

fn wide(value: &OsStr) -> Vec<u16> {
    value.encode_wide().chain(std::iter::once(0)).collect()
}

fn quote(value: &OsStr) -> String {
    // Windows CommandLineToArgvW quoting (including trailing backslashes).
    let mut output = String::from("\"");
    let mut slashes = 0;
    for character in value.to_string_lossy().chars() {
        if character == '\\' {
            slashes += 1;
        } else {
            output.extend(std::iter::repeat_n('\\', slashes * if character == '"' { 2 } else { 1 }));
            if character == '"' {
                output.push('\\');
            }
            output.push(character);
            slashes = 0;
        }
    }
    output.extend(std::iter::repeat_n('\\', slashes * 2));
    output.push('"');
    output
}

fn find_wiresock() -> Result<PathBuf> {
    if let Some(custom) = std::env::var_os("YAPFAST_WIRESOCK_EXE") {
        let path = PathBuf::from(custom);
        if path.is_file() {
            return Ok(path);
        }
        bail!("YAPFAST_WIRESOCK_EXE does not point to wiresock-client.exe");
    }
    for root in ["ProgramFiles", "ProgramFiles(x86)"]
        .into_iter()
        .filter_map(std::env::var_os)
    {
        for directory in ["WireSock Secure Connect", "WireSock VPN Client", "WireSock"] {
            for subdir in ["sdk", "bin", ""] {
                let path = PathBuf::from(&root).join(directory).join(subdir).join("wiresock-client.exe");
                if path.is_file() {
                    return Ok(path);
                }
            }
        }
    }
    bail!("WireSock CLI not found. Install WireSock Secure Connect CLI first.")
}

fn filter_profile(source: &str, worker: &Path) -> Result<String> {
    let mut peers = 0;
    let mut interface = false;
    let mut route = false;
    for line in source.lines() {
        let clean = line.trim();
        if clean.eq_ignore_ascii_case("[Interface]") {
            interface = true;
        } else if clean.eq_ignore_ascii_case("[Peer]") {
            peers += 1;
        } else if clean.starts_with('[') && clean.ends_with(']') {
            bail!("unsupported WireGuard configuration section: {clean}");
        }
        if let Some((key, value)) = clean.split_once('=') {
            let key = key.trim();
            if ["PreUp", "PostUp", "PreDown", "PostDown"].iter().any(|hook| key.eq_ignore_ascii_case(hook)) {
                bail!("WireGuard profile hooks are not permitted");
            }
            if key.eq_ignore_ascii_case("AllowedIPs")
                && value.split(',').any(|route| route.trim() == "0.0.0.0/0")
            {
                route = true;
            }
        }
    }
    if !interface || peers != 1 || !route {
        bail!("WireGuard needs [Interface], exactly one [Peer], and AllowedIPs = 0.0.0.0/0");
    }
    let mut filtered = Vec::new();
    for line in source.lines() {
        let key = line.trim_start().split_once('=').map(|(key, _)| key.trim());
        if key.is_some_and(|key| {
            ["DNS", "AllowedApps", "DisallowedApps", "#@ws:AllowedApps", "#@ws:DisallowedApps"]
                .iter().any(|skip| key.eq_ignore_ascii_case(skip))
        }) {
            continue;
        }
        filtered.push(line);
    }
    // WireSock's own per-process rule; the gateway and calls stay direct.
    filtered.push(&format!("#@ws:AllowedApps = {}", worker.display()));
    Ok(filtered.join("\r\n") + "\r\n")
}

fn unique_session(root: &Path) -> PathBuf {
    let clock = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    root.join("golive-tunnel")
        .join(format!("{}-{}", std::process::id(), clock.as_nanos()))
}

fn start_helper(
    exe: &Path,
    profile: &Path,
    worker: &Path,
    cli: &Path,
    dir: &Path,
) -> Result<HANDLE> {
    let verb = wide(OsStr::new("runas"));
    let file = wide(exe.as_os_str());
    let parameters = [
        OsString::from(HELPER_ARG),
        profile.as_os_str().to_os_string(),
        worker.as_os_str().to_os_string(),
        cli.as_os_str().to_os_string(),
        OsString::from(std::process::id().to_string()),
        dir.as_os_str().to_os_string(),
    ];
    let parameters = wide(OsStr::new(
        &parameters.iter().map(|part| quote(part)).collect::<Vec<_>>().join(" "),
    ));
    let mut info: SHELLEXECUTEINFOW = unsafe { std::mem::zeroed() };
    info.cbSize = std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
    info.fMask = SEE_MASK_NOCLOSEPROCESS;
    info.lpVerb = verb.as_ptr();
    info.lpFile = file.as_ptr();
    info.lpParameters = parameters.as_ptr();
    info.nShow = SW_HIDE;
    if unsafe { ShellExecuteExW(&mut info) } == 0 {
        return Err(io::Error::last_os_error()).context("WireSock needs administrator approval");
    }
    if info.hProcess.is_null() {
        bail!("Windows did not return a process handle for the elevated VPN helper");
    }
    Ok(info.hProcess)
}

/// Owns the temporary worker, the elevated WireSock helper and the watchdog.
/// Dropping this guard stops the tunnel; the helper also watches our PID
/// in case Windows terminates Yapfast without running Rust destructors.
pub(crate) struct Tunnel {
    directory: PathBuf,
    worker: PathBuf,
    helper: HANDLE,
    stopping: Arc<AtomicBool>,
    watchdog: Option<thread::JoinHandle<()>>,
}

impl Drop for Tunnel {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::SeqCst);
        let _ = fs::write(self.directory.join("stop"), b"");
        if let Some(watchdog) = self.watchdog.take() {
            let _ = watchdog.join();
        }
        unsafe {
            WaitForSingleObject(self.helper, 4_000);
            CloseHandle(self.helper);
        }
        let _ = fs::remove_file(&self.worker);
        let _ = fs::remove_dir_all(&self.directory);
    }
}

fn abandoned(dir: &Path, worker: &Path, helper: HANDLE) {
    let _ = fs::write(dir.join("stop"), b"");
    unsafe {
        WaitForSingleObject(helper, 3_000);
        CloseHandle(helper);
    }
    let _ = fs::remove_file(worker);
}

/// Called before the Slint window connects to Discord.
/// Returns None unless the person explicitly enabled the integration.
pub(crate) fn start(root: &Path) -> Result<Option<Tunnel>> {
    let settings = Settings::read(root);
    if !settings.enabled {
        return Ok(None);
    }
    let profile = settings.profile();
    let text = fs::read_to_string(&profile)
        .with_context(|| format!("WireGuard profile not found: {}. Choose one in Settings > Advanced.", profile.display()))?;
    let cli = find_wiresock()?;
    let exe = std::env::current_exe()?;
    // Validate locally before showing the UAC dialog.
    filter_profile(&text, &exe)?;
    let directory = unique_session(root);
    fs::create_dir_all(&directory)?;
    let worker = exe.with_file_name(format!(
        "yapfast-golive-media-{}-{}.exe",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos()
    ));
    if let Err(error) = fs::copy(&exe, &worker) {
        let _ = fs::remove_dir_all(&directory);
        return Err(error).context("cannot create the media worker next to Yapfast.exe");
    }
    let helper = match start_helper(&exe, &profile, &worker, &cli, &directory) {
        Ok(handle) => handle,
        Err(error) => {
            let _ = fs::remove_file(&worker);
            let _ = fs::remove_dir_all(&directory);
            return Err(error);
        }
    };

    let started = Instant::now();
    loop {
        if directory.join("ready").is_file() {
            break;
        }
        if directory.join("error.txt").is_file()
            || unsafe { WaitForSingleObject(helper, 0) } != WAIT_TIMEOUT
        {
            let message = fs::read_to_string(directory.join("error.txt"))
                .unwrap_or_else(|_| "WireSock exited before its VPN tunnel started.".into());
            abandoned(&directory, &worker, helper);
            bail!("Could not start WireSock: {message}");
        }
        if started.elapsed() > Duration::from_secs(12) {
            abandoned(&directory, &worker, helper);
            bail!("WireSock did not start within 12 seconds. Check its driver and VPN profile.");
        }
        thread::sleep(Duration::from_millis(150));
    }

    yapfast_core::stream_worker::set_media_worker_executable(worker.clone())?;
    let stopping = Arc::new(AtomicBool::new(false));
    let flag = stopping.clone();
    // Watch the elevated helper; if WireSock dies, fail closed instead of
    // allowing the stream worker to reconnect without the expected tunnel.
    let handle = helper as usize;
    let watchdog = thread::spawn(move || {
        loop {
            if flag.load(Ordering::SeqCst) { break; }
            let state = unsafe { WaitForSingleObject(handle as HANDLE, 350) };
            if state != WAIT_TIMEOUT && !flag.load(Ordering::SeqCst) {
                error_popup("The WireSock tunnel stopped. Yapfast must close to prevent direct media traffic. See the GoLive log in your Yapfast data folder.");
                std::process::exit(1);
            }
        }
    });
    tracing::info!(profile = %profile.display(), "WireSock media-only Go Live VPN started");
    Ok(Some(Tunnel { directory, worker, helper, stopping, watchdog: Some(watchdog) }))
}

/// The Windows-subsystem executable cannot report a fatal startup error in
/// a terminal, so show it explicitly; do not silently fall back to direct Go Live.
pub(crate) fn error_popup(message: &str) {
    let body = wide(OsStr::new(message));
    let title = wide(OsStr::new("Yapfast Go Live VPN"));
    unsafe { MessageBoxW(std::ptr::null_mut(), body.as_ptr(), title.as_ptr(), MB_OK | MB_ICONERROR); }
}

/// Elevated VPN helper. Does not open the UI or read Yapfast credentials.
pub(crate) fn helper_main(args: impl IntoIterator<Item = OsString>) -> Result<()> {
    let args: Vec<_> = args.into_iter().collect();
    if args.len() != 5 {
        bail!("invalid WireSock helper arguments");
    }
    let profile = PathBuf::from(&args[0]);
    let worker = PathBuf::from(&args[1]);
    let cli = PathBuf::from(&args[2]);
    let parent_id: u32 = args[3].to_string_lossy().parse().context("invalid helper parent")?;
    let directory = PathBuf::from(&args[4]);
    if !directory.is_dir() || !worker.is_file() || !cli.is_file() {
        bail!("invalid Go Live helper startup paths");
    }
    let result = run_helper(&directory, &profile, &worker, &cli, parent_id);
    if let Err(error) = &result {
        let message = format!("{error:#}");
        let message = redact(&message);
        let _ = fs::write(directory.join("error.txt"), message);
    }
    result
}

fn redact(text: &str) -> String {
    text.lines().map(|line| {
        let trimmed = line.trim_start();
        if ["PrivateKey", "PresharedKey"]
            .iter()
            .any(|key| trimmed.starts_with(key) && trimmed[key.len()..].trim_start().starts_with('='))
        {
            "[REDACTED]".to_owned()
        } else {
            line.to_owned()
        }
    }).collect::<Vec<_>>().join("\n")
}

fn run_helper(directory: &Path, profile: &Path, worker: &Path, cli: &Path, parent_id: u32) -> Result<()> {
    // SYNCHRONIZE: only watch for the original parent process to exit.
    let parent = unsafe { OpenProcess(0x0010_0000, 0, parent_id) };
    if parent.is_null() {
        bail!("the Yapfast process already exited");
    }
    let result = run_helper_connected(directory, profile, worker, cli, parent);
    unsafe { CloseHandle(parent); }
    result
}

fn run_helper_connected(directory: &Path, profile: &Path, worker: &Path, cli: &Path, parent: HANDLE) -> Result<()> {
    let source = fs::read_to_string(profile).context("cannot read WireGuard profile")?;
    let filtered = filter_profile(&source, worker)?;
    let temp_config = directory.join("wiresock-profile.conf");
    fs::write(&temp_config, filtered).context("cannot create filtered media profile")?;
    let log = directory.join("wiresock.log");
    let output = File::create(&log)?;
    let mut process = Command::new(cli)
        .args(["run", "-config"])
        .arg(&temp_config)
        .args(["-log-level", "info"])
        .creation_flags(NO_WINDOW)
        .stdout(Stdio::from(output.try_clone()?))
        .stderr(Stdio::from(output))
        .spawn()
        .context("cannot start WireSock CLI")?;

    let result = (|| -> Result<()> {
        // Require the child to remain running before the parent starts Discord.
        for _ in 0..10 {
            if let Some(status) = process.try_wait()? {
                let logs = fs::read_to_string(&log).unwrap_or_default();
                bail!("WireSock exited ({status}): {}", redact(&logs));
            }
            thread::sleep(Duration::from_millis(200));
        }
        fs::write(directory.join("ready"), b"")?;
        while !directory.join("stop").exists() {
            if unsafe { WaitForSingleObject(parent, 0) } != WAIT_TIMEOUT {
                break;
            }
            if let Some(status) = process.try_wait()? {
                let logs = fs::read_to_string(&log).unwrap_or_default();
                bail!("WireSock tunnel stopped ({status}): {}", redact(&logs));
            }
            thread::sleep(Duration::from_millis(250));
        }
        Ok(())
    })();
    let _ = process.kill();
    let _ = process.wait();
    let _ = fs::remove_file(&temp_config);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filter_preserves_only_media_worker_route() {
        let source = "[Interface]\nPrivateKey = secret\nDNS = 1.1.1.1\n[Peer]\nAllowedIPs = 0.0.0.0/0, ::/0\n#@ws:AllowedApps = old.exe\n";
        let text = filter_profile(source, Path::new(r"C:\Program Files\Yapfast\media.exe")).unwrap();
        assert!(text.contains("#@ws:AllowedApps = C:\\Program Files\\Yapfast\\media.exe"));
        assert!(!text.contains("DNS ="));
        assert!(!text.contains("old.exe"));
        assert!(text.contains("PrivateKey = secret"));
    }

    #[test]
    fn filter_rejects_hooks_and_partial_routes() {
        assert!(filter_profile("[Interface]\nPostUp = calc.exe\n[Peer]\nAllowedIPs = 0.0.0.0/0", Path::new("media.exe")).is_err());
        assert!(filter_profile("[Interface]\n[Peer]\nAllowedIPs = 10.0.0.0/8", Path::new("media.exe")).is_err());
    }

    #[test]
    fn windows_quotes_paths_with_spaces() {
        assert_eq!(quote(OsStr::new(r"C:\Apps\Yap Fast\")), r#""C:\Apps\Yap Fast\\""#);
    }
}
