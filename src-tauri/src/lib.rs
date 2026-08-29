use std::io::Write;
use std::net::{SocketAddr, TcpStream};
use std::path::PathBuf;
use std::process::{Child, Command};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::Duration;
use serde::Serialize;

#[cfg(windows)]
use std::os::windows::process::CommandExt;

// CREATE_NO_WINDOW (0x08000000): every spawned console process (adb,
// powershell, taskkill, scrcpy) would flash a terminal window otherwise.
// A GUI app must set this on ALL child processes or the user sees windows
// popping up constantly (esp. the 1.5s status poll spawning adb).
const CREATE_NO_WINDOW: u32 = 0x08000000;

fn silent_command(program: impl AsRef<std::ffi::OsStr>) -> Command {
    let mut cmd = Command::new(program);
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);
    cmd
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

#[derive(Serialize)]
struct EmulatorStatus {
    running: bool,
    vnc_ready: bool,
    adb_ready: bool,
    boot_completed: bool,
    scrcpy_running: bool,
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
                        let _ = silent_command("adb")
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
                            let _ = silent_command("adb")
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
                                        let _ = silent_command("adb")
                                            .args(&["-s", "127.0.0.1:5555", "shell", "input", "swipe", &dx.to_string(), &dy.to_string(), &mx.to_string(), &my.to_string(), "150"])
                                            .output();
                                    } else {
                                        let _ = silent_command("adb")
                                            .args(&["-s", "127.0.0.1:5555", "shell", "input", "tap", &dx.to_string(), &dy.to_string()])
                                            .output();
                                    }
                                } else {
                                    let _ = silent_command("adb")
                                        .args(&["-s", "127.0.0.1:5555", "shell", "input", "tap", &dx.to_string(), &dy.to_string()])
                                        .output();
                                }
                            }
                            last_down = None;
                            last_move = None;
                        }
                        5 => {
                            let _ = silent_command("adb")
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
    // 1. Check CWD and walk upward
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

    // 2. Check EXE directory and walk upward
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

    Err("Could not find repository root containing tools\\launch.ps1 (run the app from the QArmDroid repo or with the .exe inside it)".to_string())
}

#[tauri::command]
fn start_emulator(display_mode: Option<String>) -> Result<String, String> {
    if is_port_open(5901, 50) || is_port_open(5555, 50) {
        return Ok("Emulator is already running.".to_string());
    }

    let repo_root = find_repo_root()?;
    let launch_script = repo_root.join("tools").join("launch.ps1");
    // Default to embedded (VNC websocket into the Tauri window). The custom
    // QArmDroid QEMU is built with VNC enabled; the display streams over
    // ws://127.0.0.1:5901 into the noVNC canvas.
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

    match silent_command("powershell.exe")
        .current_dir(&repo_root)
        .args(&[
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            script_str,
            "-DisplayMode",
            qemu_mode,
        ])
        .spawn()
    {
        Ok(_) => Ok(format!("Emulator launched in '{}' display mode.", mode)),
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
        silent_command("adb").args(&["connect", "127.0.0.1:5555"]),
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
            silent_command("adb").args(&["-s", "127.0.0.1:5555", "get-state"]),
            Duration::from_secs(3),
        );
        let s = String::from_utf8_lossy(&output.stdout);
        if output.status.success() && s.contains("device") {
            adb_ready = true;
            let b_out = run_with_timeout(
                silent_command("adb").args(&["-s", "127.0.0.1:5555", "shell", "getprop", "sys.boot_completed"]),
                Duration::from_secs(3),
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
    let output = run_with_timeout(
        silent_command("adb").args(&["-s", "127.0.0.1:5555", "shell", "input", "keyevent", &key]),
        Duration::from_secs(5),
    );

    if output.status.success() {
        Ok("Key event sent".to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

#[tauri::command]
fn send_adb_text(text: String) -> Result<String, String> {
    let output = run_with_timeout(
        silent_command("adb").args(&["-s", "127.0.0.1:5555", "shell", "input", "text", &text]),
        Duration::from_secs(5),
    );

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
        silent_command("adb").args(&["-s", "127.0.0.1:5555", "shell", "pidof touch_daemon"]),
        Duration::from_secs(5),
    );
    let is_running = !check.stdout.is_empty();

    if !is_running {
        // Push the daemon binary
        let _ = run_with_timeout(
            silent_command("adb").args(&["-s", "127.0.0.1:5555", "push",
                    daemon_elf.to_str().unwrap(),
                    "/data/local/tmp/touch_daemon"]),
            Duration::from_secs(10),
        );

        let _ = run_with_timeout(
            silent_command("adb").args(&["-s", "127.0.0.1:5555", "shell",
                    "chmod 755 /data/local/tmp/touch_daemon; /data/local/tmp/touch_daemon &"]),
            Duration::from_secs(5),
        );
    }

    // Set up ADB port-forward so host:6666 -> guest:6666
    let _ = run_with_timeout(
        silent_command("adb").args(&["-s", "127.0.0.1:5555", "forward", "tcp:6666", "tcp:6666"]),
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
        silent_command("adb").args(&["-s", "127.0.0.1:5555", "shell", "settings put global window_animation_scale 0; settings put global transition_animation_scale 0; settings put global animator_duration_scale 0"]),
        Duration::from_secs(5),
    );

    Ok("UI animations optimized".to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
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
            optimize_performance
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

