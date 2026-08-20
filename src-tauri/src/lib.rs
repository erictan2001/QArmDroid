use std::net::{SocketAddr, TcpStream};
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;
use serde::Serialize;

#[derive(Serialize)]
struct EmulatorStatus {
    running: bool,
    vnc_ready: bool,
    adb_ready: bool,
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

#[tauri::command]
fn get_emulator_status() -> EmulatorStatus {
    let vnc_ready = is_port_open(5901);
    let adb_ready = is_port_open(5555);
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            start_emulator,
            stop_emulator,
            get_emulator_status,
            send_adb_key,
            send_adb_text
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
