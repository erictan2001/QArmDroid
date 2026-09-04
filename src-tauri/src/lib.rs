use std::fs;
use std::io::{BufRead, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::Duration;
use serde::Serialize;
use tauri::Emitter;

#[cfg(windows)]
use std::os::windows::process::CommandExt;

// CREATE_NO_WINDOW (0x08000000): every spawned console process (adb,
// powershell, taskkill, scrcpy) would flash a terminal window otherwise.
// A GUI app must set this on ALL child processes or the user sees windows
// popping up constantly (esp. the 1.5s status poll spawning adb).
const CREATE_NO_WINDOW: u32 = 0x08000000;

/// Recursively copy a directory
#[allow(dead_code)]
fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<(), String> {
    if !src.exists() {
        return Err(format!("Source directory does not exist: {}", src.display()));
    }
    
    fs::create_dir_all(dst).map_err(|e| format!("Failed to create dest dir: {}", e))?;
    
    for entry in fs::read_dir(src).map_err(|e| format!("Failed to read dir: {}", e))? {
        let entry = entry.map_err(|e| format!("Failed to read dir entry: {}", e))?;
        let src_path = entry.path();
        let dst_path = dst.join(entry.file_name());
        
        if entry.file_type().map_err(|e| format!("Failed to get file type: {}", e))?.is_dir() {
            copy_dir_recursive(&src_path, &dst_path)?;
        } else {
            fs::copy(&src_path, &dst_path).map_err(|e| format!("Failed to copy file: {}", e))?;
        }
    }
    Ok(())
}

fn silent_command(program: impl AsRef<std::ffi::OsStr>) -> Command {
    let mut cmd = Command::new(program);
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);
    cmd
}

/// Locate adb executable: prefer C:\platform-tools\adb.exe or bundled scrcpy\adb.exe, fallback to system PATH "adb"
fn adb_cmd() -> Command {
    let adb_path: PathBuf = if Path::new(r"C:\platform-tools\adb.exe").exists() {
        PathBuf::from(r"C:\platform-tools\adb.exe")
    } else if let Ok(repo_root) = find_repo_root() {
        let scrcpy_adb = repo_root.join("tools").join("scrcpy").join("adb.exe");
        if scrcpy_adb.exists() {
            scrcpy_adb
        } else {
            PathBuf::from("adb")
        }
    } else {
        PathBuf::from("adb")
    };
    silent_command(adb_path)
}

/// Run a command and capture output, killing it if it exceeds `timeout`.
/// adb can hang (device offline, ADB server starting), which would otherwise
/// block the status-poll thread and make the app feel frozen.
fn run_with_timeout(cmd: &mut Command, timeout: Duration) -> std::process::Output {
    use std::process::Stdio;
    let mut child = match cmd.stdout(Stdio::piped()).stderr(Stdio::piped()).spawn() {
        Ok(c) => c,
        Err(_) => {
            return std::process::Output {
                status: std::process::ExitStatus::default(),
                stdout: Vec::new(),
                stderr: Vec::new(),
            }
        }
    };
    let deadline = std::time::Instant::now() + timeout;
    let mut buf_out = Vec::new();
    let mut buf_err = Vec::new();
    let status = loop {
        match child.try_wait() {
            Ok(Some(st)) => break st,
            Ok(None) => {}
            Err(_) => break std::process::ExitStatus::default(),
        }
        if std::time::Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return std::process::Output {
                status: std::process::ExitStatus::default(),
                stdout: Vec::new(),
                stderr: b"timed out".to_vec(),
            };
        }
        thread::sleep(Duration::from_millis(50));
    };
    // final drain
    use std::io::Read;
    if let Some(mut o) = child.stdout.take() {
        let mut tmp = Vec::new();
        let _ = o.read_to_end(&mut tmp);
        buf_out.extend(tmp);
    }
    if let Some(mut o) = child.stderr.take() {
        let mut tmp = Vec::new();
        let _ = o.read_to_end(&mut tmp);
        buf_err.extend(tmp);
    }
    std::process::Output { status, stdout: buf_out, stderr: buf_err }
}
#[derive(Serialize, Clone, Debug)]
struct EmulatorStatus {
    running: bool,
    vnc_ready: bool,
    adb_ready: bool,
    boot_completed: bool,
    scrcpy_running: bool,
}

/// Progress update emitted to the frontend while provisioning the Android
/// image. `percent` is 0..=100, `stage` is a short human label, `done`/`error`
/// flag terminal states.
#[derive(Serialize, Clone, Debug)]
struct ProvisionProgress {
    percent: u32,
    stage: String,
    message: String,
    done: bool,
    error: bool,
}

/// Persisted image configuration (mirrors tools/provision_bundle.ps1 output
/// of image_config.json). Returned to the UI so it can prefill the setup form.
#[derive(Serialize, Clone, Debug)]
struct ImageConfig {
    installed: bool,
    provisioned: bool,
    disk_size_gb: u32,
    fs_format: String,
    runtime_root: String,
}

/// Resolve the writable runtime root where the bundled install provisions
/// QEMU + image + disk.raw (%LOCALAPPDATA%\QArmDroid). For a dev repo this is
/// just the repo root.
fn runtime_root() -> PathBuf {
    std::env::var("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
        .join("QArmDroid")
}

/// The immutable installer resources directory that ships the QEMU binary,
/// Android image inputs and build tools (e.g. C:\Program Files\QArmDroid\
/// resources). These are read-only at runtime, so provision_bundle.ps1 copies
/// them into `runtime_root()`. Returns None when not running from a bundled
/// install (dev repo), in which case the script falls back to a sibling dir.
fn install_resources() -> Option<PathBuf> {
    std::env::current_exe().ok().and_then(|e| {
        e.parent().map(|d| d.join("resources")).and_then(|r| {
            if r.join("qemu").join("qemu-system-aarch64.exe").exists() {
                Some(r)
            } else {
                None
            }
        })
    })
}

/// Read the persisted image_config.json (written by provision_bundle.ps1).
fn read_image_config() -> ImageConfig {
    let rt = runtime_root();
    let disk = rt.join("image").join("disk.raw");
    // "installed" = the app's immutable resources ship next to the exe (a real
    // bundled install). This is independent of whether provisioning has run.
    let installed = install_resources().is_some() || rt.exists();
    // "provisioned" = ground truth: the built disk.raw exists. We do NOT trust
    // the config flag, which can be left stale after a failed build.
    let provisioned = disk.exists();

    let mut disk_size_gb = 8u32;
    let mut fs_format = "ext4".to_string();

    let cfg_path = rt.join("image_config.json");
    if let Ok(contents) = fs::read_to_string(&cfg_path) {
        // Minimal JSON parse without an external crate dependency churn.
        if let Some(v) = extract_json_string(&contents, "userdata_fs") {
            fs_format = v;
        }
        if let Some(v) = extract_json_u32(&contents, "userdata_size_gb") {
            disk_size_gb = v;
        }
    }

    ImageConfig {
        installed,
        provisioned,
        disk_size_gb,
        fs_format,
        runtime_root: rt.to_string_lossy().to_string(),
    }
}

fn extract_json_string(json: &str, key: &str) -> Option<String> {
    let pat = format!("\"{}\"", key);
    let idx = json.find(&pat)?;
    let rest = &json[idx + pat.len()..];
    let colon = rest.find(':')?;
    let val = rest[colon + 1..].trim_start();
    let start = val.find('"')?;
    let end = val[start + 1..].find('"')?;
    Some(val[start + 1..start + 1 + end].to_string())
}

fn extract_json_u32(json: &str, key: &str) -> Option<u32> {
    let pat = format!("\"{}\"", key);
    let idx = json.find(&pat)?;
    let rest = &json[idx + pat.len()..];
    let colon = rest.find(':')?;
    let val = rest[colon + 1..].trim_start();
    val.split(',').next()?.trim().parse::<u32>().ok()
}

fn extract_json_bool(json: &str, key: &str) -> Option<bool> {
    let pat = format!("\"{}\"", key);
    let idx = json.find(&pat)?;
    let rest = &json[idx + pat.len()..];
    let colon = rest.find(':')?;
    let val = rest[colon + 1..].trim_start();
    let v = val.split(',').next()?.trim().trim_end_matches('}').trim();
    match v {
        "true" => Some(true),
        "false" => Some(false),
        _ => None,
    }
}

// Asynchronous non-blocking background touch worker.
// Guarantees that Tauri invoke threads and UI never block on network sockets or Mutexes.
static TOUCH_SENDER: OnceLock<Sender<[u8; 14]>> = OnceLock::new();

fn get_touch_sender() -> &'static Sender<[u8; 14]> {
    TOUCH_SENDER.get_or_init(|| {
        let (tx, rx) = channel::<[u8; 14]>();

        thread::spawn(move || {
            let addr: SocketAddr = "127.0.0.1:6666".parse().unwrap();
            let mut stream: Option<TcpStream> = None;
            let mut last_down: Option<(u16, u16)> = None;
            let mut last_move: Option<(u16, u16)> = None;

            while let Ok(packet) = rx.recv() {
                let mut sent = false;
                if let Some(ref mut s) = stream {
                    if s.write_all(&packet).is_ok() {
                        sent = true;
                    }
                }

                if !sent {
                    stream = None;
                    // Attempt quick connect
                    if let Ok(mut s) = TcpStream::connect_timeout(&addr, Duration::from_millis(50)) {
                        s.set_nodelay(true).ok();
                        if s.write_all(&packet).is_ok() {
                            stream = Some(s);
                            sent = true;
                        }
                    } else {
                        // Ensure ADB port forward is active and retry once
                        let _ = adb_cmd()
                            .args(&["-s", "127.0.0.1:5555", "forward", "tcp:6666", "tcp:6666"])
                            .output();
                        if let Ok(mut s) = TcpStream::connect_timeout(&addr, Duration::from_millis(80)) {
                            s.set_nodelay(true).ok();
                            if s.write_all(&packet).is_ok() {
                                stream = Some(s);
                                sent = true;
                            }
                        }
                    }
                }

                // If TCP daemon was temporarily unavailable, dispatch via ADB in background
                if !sent {
                    let cmd = packet[0];
                    let x1 = (packet[2] as u16) | ((packet[3] as u16) << 8);
                    let y1 = (packet[4] as u16) | ((packet[5] as u16) << 8);
                    let x2 = (packet[6] as u16) | ((packet[7] as u16) << 8);
                    let y2 = (packet[8] as u16) | ((packet[9] as u16) << 8);
                    let dur = (packet[10] as u16) | ((packet[11] as u16) << 8);

                    match cmd {
                        1 => {
                            let _ = adb_cmd()
                                .args(&["-s", "127.0.0.1:5555", "shell", "input", "tap", &x1.to_string(), &y1.to_string()])
                                .output();
                        }
                        2 => {
                            last_down = Some((x1, y1));
                            last_move = None;
                        }
                        3 => {
                            last_move = Some((x1, y1));
                        }
                        4 => {
                            if let Some((dx, dy)) = last_down {
                                if let Some((mx, my)) = last_move {
                                    let dist = ((mx as i32 - dx as i32).abs() + (my as i32 - dy as i32).abs()) as u32;
                                    if dist > 15 {
                                        let _ = adb_cmd()
                                            .args(&["-s", "127.0.0.1:5555", "shell", "input", "swipe", &dx.to_string(), &dy.to_string(), &mx.to_string(), &my.to_string(), "150"])
                                            .output();
                                    } else {
                                        let _ = adb_cmd()
                                            .args(&["-s", "127.0.0.1:5555", "shell", "input", "tap", &dx.to_string(), &dy.to_string()])
                                            .output();
                                    }
                                } else {
                                    let _ = adb_cmd()
                                        .args(&["-s", "127.0.0.1:5555", "shell", "input", "tap", &dx.to_string(), &dy.to_string()])
                                        .output();
                                }
                            }
                            last_down = None;
                            last_move = None;
                        }
                        5 => {
                            let _ = adb_cmd()
                                .args(&["-s", "127.0.0.1:5555", "shell", "input", "swipe", &x1.to_string(), &y1.to_string(), &x2.to_string(), &y2.to_string(), &dur.to_string()])
                                .output();
                        }
                        _ => {}
                    }
                }
            }
        });

        tx
    })
}

fn touch_send_async(packet: [u8; 14]) -> Result<(), String> {
    let sender = get_touch_sender();
    sender.send(packet).map_err(|e| format!("Channel error: {}", e))
}

fn build_packet(cmd: u8, x1: u16, y1: u16, x2: u16, y2: u16, dur: u16) -> [u8; 14] {
    let mut p = [0u8; 14];
    p[0] = cmd;
    p[2] = (x1 & 0xff) as u8;
    p[3] = (x1 >> 8) as u8;
    p[4] = (y1 & 0xff) as u8;
    p[5] = (y1 >> 8) as u8;
    p[6] = (x2 & 0xff) as u8;
    p[7] = (x2 >> 8) as u8;
    p[8] = (y2 & 0xff) as u8;
    p[9] = (y2 >> 8) as u8;
    p[10] = (dur & 0xff) as u8;
    p[11] = (dur >> 8) as u8;
    p
}

fn find_repo_root() -> Result<PathBuf, String> {
    // 1. Bundled (installed) deployment: resources\qemu\qemu-system-aarch64.exe
    //    sits next to the exe under <install>\resources\qemu\. The app also
    //    provisions a writable runtime under %LOCALAPPDATA%\QArmDroid; prefer
    //    that once it exists (it holds launch.ps1 + image/disk.raw).
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let bundled_res = dir.join("resources");
            if bundled_res.join("qemu").join("qemu-system-aarch64.exe").exists() {
                // Provisioned runtime (first run copies + builds disk.raw).
                let rt = std::env::var("LOCALAPPDATA")
                    .map(PathBuf::from)
                    .unwrap_or_else(|_| bundled_res.clone());
                let rt = rt.join("QArmDroid");
                if rt.join("tools").join("launch.ps1").exists() {
                    return Ok(rt);
                }
                return Ok(bundled_res);
            }
        }
    }

    // 1b. Check CWD and walk upward
    if let Ok(cwd) = std::env::current_dir() {
        let mut curr = cwd.clone();
        for _ in 0..5 {
            if curr.join("tools").join("launch.ps1").exists() {
                return Ok(curr);
            }
            if !curr.pop() {
                break;
            }
        }
    }

    // 2. Check EXE directory and walk upward (dev: exe inside repo)
    if let Ok(exe) = std::env::current_exe() {
        let mut curr = exe.clone();
        for _ in 0..6 {
            if curr.join("tools").join("launch.ps1").exists() {
                return Ok(curr);
            }
            if !curr.pop() {
                break;
            }
        }
    }

    Err("Could not find repository root (repo with tools\\launch.ps1, or bundled resources\\qemu).".to_string())
}

#[tauri::command]
fn start_emulator(display_mode: Option<String>) -> Result<String, String> {
    if is_port_open(5901, 50) || is_port_open(5555, 50) {
        return Ok("Emulator is already running.".to_string());
    }

    let repo_root = find_repo_root()?;

    // Bundled install: resources\qemu\qemu-system-aarch64.exe exists next to
    // the exe. The runtime (QEMU/image/disk.raw) is provisioned by the user
    // explicitly via the Setup panel, NOT automatically on first launch.
    let inst_resources = std::env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(|d| d.join("resources")))
        .filter(|r| r.join("qemu").join("qemu-system-aarch64.exe").exists());
    let bundled = inst_resources.is_some();

    let runtime_root = if bundled {
        std::env::var("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|_| repo_root.clone())
            .join("QArmDroid")
    } else {
        repo_root.clone()
    };

    // Require an already-provisioned image. The UI gates launch behind the
    // Setup panel, but guard here too so a stray launch can't silently
    // start a missing-disk run.
    let disk = runtime_root.join("image").join("disk.raw");
    if bundled && !disk.exists() {
        return Err(
            "Android image is not installed yet. Open 'Configure Image' and click Install.".to_string(),
        );
    }

    // Resolve which launch.ps1 to run. The runtime root (LOCALAPPDATA\QArmDroid)
    // is ALWAYS the `-BundleRoot` because that is where provisioning puts qemu,
    // kernel, initrd and disk.raw. The Program Files `resources` dir holds the
    // immutable inputs only and has no disk.raw, so it is never a valid bundle
    // root. On a fresh provision the runtime tools copy of launch.ps1 exists;
    // if it is somehow missing, self-heal by copying it from the install or
    // dev-repo tools dir (and provision_bundle.ps1 too, so future installs work).
    let launch_script = runtime_root.join("tools").join("launch.ps1");
    if !launch_script.exists() {
        let script_src: Option<PathBuf> = std::env::current_exe()
            .ok()
            .and_then(|e| e.parent().map(|d| d.join("resources")))
            .map(|r| r.join("tools").join("launch.ps1"))
            .filter(|p| p.exists());
        let script_src = if script_src.is_some() {
            script_src
        } else {
            let r = repo_root.join("tools").join("launch.ps1");
            if r.exists() {
                Some(r)
            } else {
                None
            }
        };
        if let Some(src) = script_src {
            let tools_dir = runtime_root.join("tools");
            let _ = fs::create_dir_all(&tools_dir);
            let _ = fs::copy(&src, &launch_script);
            // Also ensure provision_bundle.ps1 is present for future installs.
            let prov_src = src.parent().unwrap().join("provision_bundle.ps1");
            if prov_src.exists() {
                let _ = fs::copy(&prov_src, tools_dir.join("provision_bundle.ps1"));
            }
        }
        if !launch_script.exists() {
            return Err(format!(
                "launch.ps1 not found at {:?} (re-run 'Configure Image' > Install)",
                launch_script
            ));
        }
    }

    start_emulator_with(&runtime_root, &runtime_root, display_mode)
}

/// Shared launcher used by both bundled and dev paths.
fn start_emulator_with(
    runtime_root: &Path,
    bundle_root: &Path,
    display_mode: Option<String>,
) -> Result<String, String> {
    let launch_script = runtime_root.join("tools").join("launch.ps1");
    let mode = display_mode.unwrap_or_else(|| "embedded".to_string());
    let qemu_mode = match mode.as_str() {
        "scrcpy" => "none",
        "embedded" => "embedded",
        "sdl" => "sdl",
        other => other,
    };

    let script_str = launch_script
        .to_str()
        .ok_or_else(|| "Failed to convert script path to string".to_string())?;

    let mut args = vec![
        "-NoProfile".to_string(),
        "-ExecutionPolicy".to_string(),
        "Bypass".to_string(),
        "-File".to_string(),
        script_str.to_string(),
        "-DisplayMode".to_string(),
        qemu_mode.to_string(),
    ];
    args.push("-BundleRoot".to_string());
    args.push(bundle_root.to_str().unwrap_or("").to_string());

    // SDL shows the virtio-gpu framebuffer directly (no VNC/scrcpy encoder
    // in between). With the default minigbm gralloc the scanout is BGR ->
    // red/blue look swapped in the native window. Switching to the CPU
    // gralloc ('default') produces an RGB scanout, fixing the swap.
    if qemu_mode == "sdl" {
        args.push("-GrallockOverride".to_string());
        args.push("default".to_string());
    }

    match silent_command("powershell.exe")
        .current_dir(runtime_root)
        .args(&args)
        .spawn()
    {
        Ok(_) => {
            // In the background, auto-connect ADB as soon as port 5555 is ready
            std::thread::spawn(|| {
                for _ in 0..60 {
                    std::thread::sleep(Duration::from_secs(2));
                    if is_port_open(5555, 100) {
                        let _ = adb_cmd().args(&["connect", "127.0.0.1:5555"]).output();
                        if let Ok(out) = adb_cmd().args(&["-s", "127.0.0.1:5555", "get-state"]).output() {
                            if String::from_utf8_lossy(&out.stdout).contains("device") {
                                break;
                            }
                        }
                    }
                }
            });
            Ok(format!("Emulator launched in '{}' display mode.", mode))
        }
        Err(e) => Err(format!("Failed to start emulator: {}", e)),
    }
}

static SCRCPY_PROCESS: Mutex<Option<Child>> = Mutex::new(None);

#[tauri::command]
fn launch_scrcpy() -> Result<String, String> {
    let repo_root = find_repo_root()?;
    let scrcpy_exe = repo_root.join("tools").join("scrcpy").join("scrcpy.exe");
    if !scrcpy_exe.exists() {
        return Err(format!("scrcpy.exe not found at {:?}", scrcpy_exe));
    }

    let mut lock = SCRCPY_PROCESS.lock().unwrap();
    if let Some(ref mut child) = *lock {
        if let Ok(None) = child.try_wait() {
            return Ok("scrcpy is already running".to_string());
        }
    }

    let scrcpy_dir = repo_root.join("tools").join("scrcpy");
    let scrcpy_server = scrcpy_dir.join("scrcpy-server");

    // Ensure adb connection is established
    let _ = run_with_timeout(
        adb_cmd().args(&["connect", "127.0.0.1:5555"]),
        Duration::from_secs(5),
    );

    // Canonical scrcpy stream config — measured optimum (PERFORMANCE.md):
    // the guest's software H264 encoder saturates around 11-13 fps at
    // 60fps/4M; capping to 30fps/960p/2M keeps the stream stable instead of
    // bursty, which reads as smoother. Do not raise silently.
    let child = silent_command(&scrcpy_exe)
        .current_dir(&scrcpy_dir)
        .env("SCRCPY_SERVER_PATH", &scrcpy_server)
        .args(&[
            "-s", "127.0.0.1:5555",
            "--window-title=Arm64 Android 16 Emulator",
            "--max-fps=30",
            "-m", "960",
            "-b", "2M",
            "--video-codec=h264",
            "--render-driver=direct3d11",
            "--stay-awake",
            "--power-off-on-close",
            "--no-audio",
        ])
        .spawn()
        .map_err(|e| format!("Failed to spawn scrcpy: {}", e))?;

    *lock = Some(child);
    Ok("scrcpy launched successfully".to_string())
}

#[tauri::command]
fn stop_scrcpy() -> Result<String, String> {
    let mut lock = SCRCPY_PROCESS.lock().unwrap();
    if let Some(ref mut child) = *lock {
        let _ = child.kill();
        *lock = None;
    }
    let _ = silent_command("taskkill")
        .args(&["/F", "/IM", "scrcpy.exe"])
        .output();

    Ok("scrcpy stopped".to_string())
}

#[tauri::command]
fn stop_emulator() -> Result<String, String> {
    let _ = stop_scrcpy();

    // Kill QEMU process on Windows
    let _ = silent_command("taskkill")
        .args(&["/F", "/IM", "qemu-system-aarch64.exe"])
        .output();

    Ok("Emulator stopped.".to_string())
}

fn is_port_open(port: u16, timeout_ms: u64) -> bool {
    let addr: SocketAddr = format!("127.0.0.1:{}", port).parse().unwrap();
    TcpStream::connect_timeout(&addr, Duration::from_millis(timeout_ms)).is_ok()
}

#[tauri::command]
fn get_emulator_status() -> EmulatorStatus {
    let vnc_ready = is_port_open(5901, 30);
    let port_5555 = is_port_open(5555, 30);
    let daemon_ready = is_port_open(6666, 30);
    let running = vnc_ready || port_5555 || daemon_ready;

    let mut adb_ready = false;
    let mut boot_completed = false;

    if port_5555 {
        let output = run_with_timeout(
            adb_cmd().args(&["-s", "127.0.0.1:5555", "get-state"]),
            Duration::from_millis(400),
        );
        let s = String::from_utf8_lossy(&output.stdout);
        if output.status.success() && s.contains("device") {
            adb_ready = true;
        } else {
            // Port 5555 is open, but device is not registered in ADB client; connect now
            let _ = run_with_timeout(
                adb_cmd().args(&["connect", "127.0.0.1:5555"]),
                Duration::from_millis(800),
            );
            let check = run_with_timeout(
                adb_cmd().args(&["-s", "127.0.0.1:5555", "get-state"]),
                Duration::from_millis(400),
            );
            if check.status.success() && String::from_utf8_lossy(&check.stdout).contains("device") {
                adb_ready = true;
            }
        }

        if adb_ready {
            let b_out = run_with_timeout(
                adb_cmd().args(&["-s", "127.0.0.1:5555", "shell", "getprop", "sys.boot_completed"]),
                Duration::from_millis(500),
            );
            let b = String::from_utf8_lossy(&b_out.stdout);
            if b.trim() == "1" {
                boot_completed = true;
            }
        }
    }

    let mut scrcpy_running = false;
    if let Ok(mut lock) = SCRCPY_PROCESS.lock() {
        if let Some(ref mut child) = *lock {
            if let Ok(None) = child.try_wait() {
                scrcpy_running = true;
            } else {
                *lock = None;
            }
        }
    }

    EmulatorStatus {
        running,
        vnc_ready,
        adb_ready,
        boot_completed,
        scrcpy_running,
    }
}

#[tauri::command]
fn send_adb_key(key: String) -> Result<String, String> {
    let mut output = run_with_timeout(
        adb_cmd().args(&["-s", "127.0.0.1:5555", "shell", "input", "keyevent", &key]),
        Duration::from_secs(3),
    );

    if !output.status.success() {
        // Attempt connect and retry
        let _ = run_with_timeout(
            adb_cmd().args(&["connect", "127.0.0.1:5555"]),
            Duration::from_secs(2),
        );
        output = run_with_timeout(
            adb_cmd().args(&["-s", "127.0.0.1:5555", "shell", "input", "keyevent", &key]),
            Duration::from_secs(3),
        );
    }

    if output.status.success() {
        Ok("Key event sent".to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

#[tauri::command]
fn send_adb_text(text: String) -> Result<String, String> {
    let mut output = run_with_timeout(
        adb_cmd().args(&["-s", "127.0.0.1:5555", "shell", "input", "text", &text]),
        Duration::from_secs(3),
    );

    if !output.status.success() {
        // Attempt connect and retry
        let _ = run_with_timeout(
            adb_cmd().args(&["connect", "127.0.0.1:5555"]),
            Duration::from_secs(2),
        );
        output = run_with_timeout(
            adb_cmd().args(&["-s", "127.0.0.1:5555", "shell", "input", "text", &text]),
            Duration::from_secs(3),
        );
    }

    if output.status.success() {
        Ok("Text sent".to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

// Deploy and start the native zero-latency touch daemon inside the Android guest.
// The daemon writes directly to /dev/input/event* (no Dalvik VM, no shell overhead).
#[tauri::command]
fn deploy_touch_daemon() -> Result<String, String> {
    let repo_root = find_repo_root()?;
    let daemon_elf = repo_root.join("tools").join("touch_daemon.elf");

    if !daemon_elf.exists() {
        return Err("touch_daemon.elf not found in tools/".to_string());
    }

    // Check if daemon is already running
    let check = run_with_timeout(
        adb_cmd().args(&["-s", "127.0.0.1:5555", "shell", "pidof touch_daemon"]),
        Duration::from_secs(5),
    );
    let is_running = !check.stdout.is_empty();

    if !is_running {
        // Push the daemon binary
        let _ = run_with_timeout(
            adb_cmd().args(&["-s", "127.0.0.1:5555", "push",
                    daemon_elf.to_str().unwrap(),
                    "/data/local/tmp/touch_daemon"]),
            Duration::from_secs(10),
        );

        let _ = run_with_timeout(
            adb_cmd().args(&["-s", "127.0.0.1:5555", "shell",
                    "chmod 755 /data/local/tmp/touch_daemon; /data/local/tmp/touch_daemon &"]),
            Duration::from_secs(5),
        );
    }

    // Set up ADB port-forward so host:6666 -> guest:6666
    let _ = run_with_timeout(
        adb_cmd().args(&["-s", "127.0.0.1:5555", "forward", "tcp:6666", "tcp:6666"]),
        Duration::from_secs(5),
    );

    Ok("Touch daemon deployed and active".to_string())
}

// ---- Touch commands: try native daemon first, fallback to ADB ----

// ---- Zero-latency non-blocking native touch commands (Pure TCP, No ADB overhead) ----

#[tauri::command]
fn send_touch_tap(x: u32, y: u32) -> Result<String, String> {
    let pkt = build_packet(1, x as u16, y as u16, 0, 0, 0);
    touch_send_async(pkt)?;
    Ok("Tap sent".to_string())
}

#[tauri::command]
fn send_touch_swipe(x1: u32, y1: u32, x2: u32, y2: u32, duration_ms: Option<u32>) -> Result<String, String> {
    let dur = duration_ms.unwrap_or(200) as u16;
    let pkt = build_packet(5, x1 as u16, y1 as u16, x2 as u16, y2 as u16, dur);
    touch_send_async(pkt)?;
    Ok("Swipe sent".to_string())
}

#[tauri::command]
fn send_motion_down(x: u32, y: u32) -> Result<(), String> {
    let pkt = build_packet(2, x as u16, y as u16, 0, 0, 0);
    touch_send_async(pkt)
}

#[tauri::command]
fn send_motion_move(x: u32, y: u32) -> Result<(), String> {
    let pkt = build_packet(3, x as u16, y as u16, 0, 0, 0);
    touch_send_async(pkt)
}

#[tauri::command]
fn send_motion_up(_x: u32, _y: u32) -> Result<(), String> {
    let pkt = build_packet(4, 0, 0, 0, 0, 0);
    touch_send_async(pkt)
}

#[tauri::command]
fn optimize_performance() -> Result<String, String> {
    // Disable window, transition, and animator scales in Android guest for instant UI responsiveness
    let _ = run_with_timeout(
        adb_cmd().args(&["-s", "127.0.0.1:5555", "shell", "settings put global window_animation_scale 0; settings put global transition_animation_scale 0; settings put global animator_duration_scale 0"]),
        Duration::from_secs(5),
    );

    Ok("UI animations optimized".to_string())
}

// --------------------------------------------------------------- image setup --
// Guard so the UI can't kick off two concurrent provisions.
static PROVISIONING: Mutex<bool> = Mutex::new(false);

#[tauri::command]
fn get_image_config() -> ImageConfig {
    read_image_config()
}

#[tauri::command]
fn save_image_config(disk_size_gb: u32, fs_format: String) -> Result<ImageConfig, String> {
    let rt = runtime_root();
    let cfg_path = rt.join("image_config.json");
    let mut cfg_provisioned = false;
    if let Ok(contents) = fs::read_to_string(&cfg_path) {
        if let Some(v) = extract_json_bool(&contents, "provisioned") {
            cfg_provisioned = v;
        }
    }
    // Only update the user-editable preferences; keep provisioned flag.
    let json = format!(
        "{{\"userdata_size_gb\":{},\"userdata_fs\":\"{}\",\"provisioned\":{}}}",
        disk_size_gb, fs_format, cfg_provisioned
    );
    if let Some(parent) = cfg_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    fs::write(&cfg_path, json).map_err(|e| format!("Failed to save config: {}", e))?;
    Ok(read_image_config())
}

/// Run the provisioning script to completion on a BACKGROUND thread so the
/// UI stays responsive (the disk build can take 10-20 minutes). Progress is
/// streamed to the frontend via `provision-progress` events. Returns
/// immediately with a startup message; the UI tracks lifecycle via events.
#[tauri::command]
async fn provision_image(app: tauri::AppHandle, force: Option<bool>, disk_size_gb: Option<u32>, fs_format: Option<String>) -> Result<String, String> {
    // Refuse concurrent runs.
    {
        let mut lock = PROVISIONING.lock().unwrap();
        if *lock {
            return Err("Image provisioning is already in progress.".to_string());
        }
        *lock = true;
    }

    let rt = runtime_root();
    let runtime_provision = rt.join("tools").join("provision_bundle.ps1");
    // Prefer the runtime tools copy; fall back to the immutable install
    // resources tools dir (used on a fresh runtime before the first
    // provisioning has copied scripts into %LOCALAPPDATA%\QArmDroid\tools),
    // then to the dev repo root.
    let provision_script = if runtime_provision.exists() {
        runtime_provision
    } else if let Some(inst) = install_resources() {
        let from_inst = inst.join("tools").join("provision_bundle.ps1");
        if from_inst.exists() {
            from_inst
        } else {
            match find_repo_root() {
                Ok(r) => r.join("tools").join("provision_bundle.ps1"),
                Err(_) => runtime_provision,
            }
        }
    } else {
        match find_repo_root() {
            Ok(r) => r.join("tools").join("provision_bundle.ps1"),
            Err(_) => runtime_provision,
        }
    };

    if !provision_script.exists() {
        *PROVISIONING.lock().unwrap() = false;
        return Err(format!("provision_bundle.ps1 not found at {:?}", provision_script));
    }

    let force = force.unwrap_or(false);
    let gb = disk_size_gb.unwrap_or(8).clamp(4, 256);
    let fs = fs_format.unwrap_or_else(|| "ext4".to_string());
    let fs = if fs == "f2fs" { "f2fs" } else { "ext4" };

    let mut args = vec![
        "-NoProfile".to_string(),
        "-ExecutionPolicy".to_string(),
        "Bypass".to_string(),
        "-File".to_string(),
        provision_script.to_string_lossy().to_string(),
        "-RuntimeRoot".to_string(),
        rt.to_string_lossy().to_string(),
        "-DiskSizeGB".to_string(),
        gb.to_string(),
        "-FsFormat".to_string(),
        fs.to_string(),
    ];
    // Point the script at the immutable installer inputs (Program Files
    // resources). Without this it would try to copy QEMU/image from the
    // writable runtime dir, which fails ("runtime missing").
    if let Some(inst) = install_resources() {
        args.push("-InstallRoot".to_string());
        args.push(inst.to_string_lossy().to_string());
    }
    if force {
        args.push("-Force".to_string());
    }

    let app2 = app.clone();
    let _ = app.emit(
        "provision-progress",
        ProvisionProgress {
            percent: 0,
            stage: "Starting".into(),
            message: "Preparing to install the Android image...".into(),
            done: false,
            error: false,
        },
    );

    // Spawn the blocking work on a dedicated thread; the async command returns
    // immediately so the webview event loop never stalls.
    std::thread::spawn(move || {
        let emit = |p: &ProvisionProgress| {
            let _ = app2.emit("provision-progress", p.clone());
        };

        let mut child = match silent_command("powershell.exe")
            .args(&args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
        {
            Ok(c) => c,
            Err(e) => {
                emit(&ProvisionProgress {
                    percent: 0,
                    stage: "Error".into(),
                    message: format!("Failed to start provisioning: {}", e),
                    done: false,
                    error: true,
                });
                *PROVISIONING.lock().unwrap() = false;
                return;
            }
        };

        // Stream stdout, parse `PROGRESS <pct> <stage>` lines, forward them.
        if let Some(out) = child.stdout.take() {
            let reader = std::io::BufReader::new(out);
            for line in reader.lines() {
                if let Ok(l) = line {
                    let trimmed = l.trim();
                    if let Some(rest) = trimmed.strip_prefix("PROGRESS ") {
                        let mut parts = rest.splitn(2, ' ');
                        if let (Some(pct_s), Some(stage)) = (parts.next(), parts.next()) {
                            if let Ok(pct) = pct_s.parse::<u32>() {
                                let is_err = stage.to_lowercase().contains("error");
                                emit(&ProvisionProgress {
                                    percent: pct.min(100),
                                    stage: stage.to_string(),
                                    message: l,
                                    done: pct >= 100 && !is_err,
                                    error: is_err,
                                });
                            }
                        }
                    }
                }
            }
        }

        // Wait for completion and emit the terminal state.
        match child.wait() {
            Ok(s) if s.success() => {
                emit(&ProvisionProgress {
                    percent: 100,
                    stage: "Complete".into(),
                    message: "Android image installed. You can now launch the emulator.".into(),
                    done: true,
                    error: false,
                });
            }
            Ok(s) => {
                emit(&ProvisionProgress {
                    percent: 0,
                    stage: "Error".into(),
                    message: format!("Provisioning exited with status {}", s),
                    done: false,
                    error: true,
                });
            }
            Err(e) => {
                emit(&ProvisionProgress {
                    percent: 0,
                    stage: "Error".into(),
                    message: format!("Failed to wait on provisioning: {}", e),
                    done: false,
                    error: true,
                });
            }
        }
        *PROVISIONING.lock().unwrap() = false;
    });

    Ok("Image provisioning started in the background.".to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|_app| {
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            start_emulator,
            stop_emulator,
            launch_scrcpy,
            stop_scrcpy,
            get_emulator_status,
            send_adb_key,
            send_adb_text,
            send_touch_tap,
            send_touch_swipe,
            send_motion_down,
            send_motion_move,
            send_motion_up,
            deploy_touch_daemon,
            optimize_performance,
            get_image_config,
            save_image_config,
            provision_image
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

