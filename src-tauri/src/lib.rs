use std::io::Write;
use std::net::{SocketAddr, TcpStream};
use std::path::PathBuf;
use std::process::Command;
use std::sync::mpsc::{channel, Sender};
use std::sync::OnceLock;
use std::thread;
use std::time::Duration;
use serde::Serialize;

#[derive(Serialize)]
struct EmulatorStatus {
    running: bool,
    vnc_ready: bool,
    adb_ready: bool,
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
                        }
                    } else {
                        // Ensure ADB port forward is active and retry once
                        let _ = Command::new("adb")
                            .args(&["-s", "127.0.0.1:5555", "forward", "tcp:6666", "tcp:6666"])
                            .output();
                        if let Ok(mut s) = TcpStream::connect_timeout(&addr, Duration::from_millis(80)) {
                            s.set_nodelay(true).ok();
                            if s.write_all(&packet).is_ok() {
                                stream = Some(s);
                            }
                        }
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

fn is_port_open(port: u16) -> bool {
    let addr: SocketAddr = format!("127.0.0.1:{}", port).parse().unwrap();
    TcpStream::connect_timeout(&addr, Duration::from_millis(250)).is_ok()
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

    // 3. Absolute known path fallback
    let fallback = PathBuf::from(r"C:\Users\erict\OneDrive\Desktop\Arm64AndroidEmulator");
    if fallback.join("tools").join("launch.ps1").exists() {
        return Ok(fallback);
    }

    Err("Could not find repository root containing tools\\launch.ps1".to_string())
}

#[tauri::command]
fn start_emulator(display_mode: Option<String>) -> Result<String, String> {
    if is_port_open(5901) || is_port_open(5555) {
        return Ok("Emulator is already running.".to_string());
    }

    let repo_root = find_repo_root()?;
    let launch_script = repo_root.join("tools").join("launch.ps1");
    let mode = display_mode.unwrap_or_else(|| "embedded".to_string());

    let script_str = launch_script
        .to_str()
        .ok_or_else(|| "Failed to convert script path to string".to_string())?;

    match Command::new("powershell.exe")
        .current_dir(&repo_root)
        .args(&[
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            script_str,
            "-DisplayMode",
            &mode,
        ])
        .spawn()
    {
        Ok(_) => Ok(format!("Emulator launched in '{}' display mode.", mode)),
        Err(e) => Err(format!("Failed to start emulator: {}", e)),
    }
}

#[tauri::command]
fn stop_emulator() -> Result<String, String> {
    // Kill QEMU process on Windows
    let _ = Command::new("taskkill")
        .args(&["/F", "/IM", "qemu-system-aarch64.exe"])
        .output();

    Ok("Emulator stopped.".to_string())
}

fn is_adb_ready() -> bool {
    // Non-destructive check to avoid dropping active ADB TCP sockets
    Command::new("adb")
        .args(&["-s", "127.0.0.1:5555", "get-state"])
        .output()
        .map(|o| {
            let out = String::from_utf8_lossy(&o.stdout);
            out.contains("device")
        })
        .unwrap_or(false)
}

#[tauri::command]
fn get_emulator_status() -> EmulatorStatus {
    let vnc_ready = is_port_open(5901);
    let adb_ready = is_adb_ready();
    let running = vnc_ready || adb_ready;

    EmulatorStatus {
        running,
        vnc_ready,
        adb_ready,
    }
}

#[tauri::command]
fn send_adb_key(key: String) -> Result<String, String> {
    let output = Command::new("adb")
        .args(&["-s", "127.0.0.1:5555", "shell", "input", "keyevent", &key])
        .output()
        .map_err(|e| format!("ADB error: {}", e))?;

    if output.status.success() {
        Ok("Key event sent".to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

#[tauri::command]
fn send_adb_text(text: String) -> Result<String, String> {
    let output = Command::new("adb")
        .args(&["-s", "127.0.0.1:5555", "shell", "input", "text", &text])
        .output()
        .map_err(|e| format!("ADB error: {}", e))?;

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
    let check = Command::new("adb")
        .args(&["-s", "127.0.0.1:5555", "shell", "pidof touch_daemon"])
        .output();
    let is_running = check.map(|o| !o.stdout.is_empty()).unwrap_or(false);

    if !is_running {
        // Push the daemon binary
        let _ = Command::new("adb")
            .args(&["-s", "127.0.0.1:5555", "push",
                    daemon_elf.to_str().unwrap(),
                    "/data/local/tmp/touch_daemon"])
            .output();

        let _ = Command::new("adb")
            .args(&["-s", "127.0.0.1:5555", "shell",
                    "chmod 755 /data/local/tmp/touch_daemon; /data/local/tmp/touch_daemon &"])
            .output();
    }

    // Set up ADB port-forward so host:6666 -> guest:6666
    let _ = Command::new("adb")
        .args(&["-s", "127.0.0.1:5555", "forward", "tcp:6666", "tcp:6666"])
        .output();

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
    let _ = Command::new("adb")
        .args(&["-s", "127.0.0.1:5555", "shell", "settings put global window_animation_scale 0; settings put global transition_animation_scale 0; settings put global animator_duration_scale 0"])
        .output();

    Ok("UI animations optimized".to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            start_emulator,
            stop_emulator,
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

