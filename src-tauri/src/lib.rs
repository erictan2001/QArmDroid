use std::process::Command;

// Learn more about Tauri commands at https://tauri.app/develop/calling-rust/
#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {}! You've been greeted from Rust!", name)
}

#[tauri::command]
fn start_emulator(image_path: Option<String>) -> Result<String, String> {
    let qemu_path = "C:\\msys64\\clangarm64\\bin\\qemu-system-aarch64.exe";
    
    let mut args = vec![
        "-accel".to_string(), "whpx".to_string(),
        "-cpu".to_string(), "host".to_string(),
        "-machine".to_string(), "virt".to_string(),
        "-m".to_string(), "4G".to_string(),
        "-device".to_string(), "virtio-gpu-gl-pci,blob=on,venus=on,hostmem=2G".to_string(),
        "-display".to_string(), "sdl,gl=on".to_string(),
        "-device".to_string(), "virtio-net-pci,netdev=net0".to_string(),
        "-netdev".to_string(), "user,id=net0".to_string(),
        "-device".to_string(), "virtio-mouse-pci".to_string(),
        "-device".to_string(), "virtio-keyboard-pci".to_string(),
        "-serial".to_string(), "mon:stdio".to_string(),
    ];

    if let Some(mut path) = image_path {
        // Remove surrounding quotes if present (e.g. from Shift + Right Click "Copy as Path")
        path = path.trim_matches('\"').trim_matches('\'').to_string();
        
        args.push("-drive".to_string());
        // Use file: prefix to avoid "Unknown protocol" errors with Windows drive letters
        args.push(format!("file=file:{},format=raw,if=virtio", path));
    }

    match Command::new(qemu_path)
        .args(&args)
        .spawn() {
            Ok(_) => Ok("Emulator started successfully".to_string()),
            Err(e) => Err(format!("Failed to start emulator: {}", e)),
        }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![greet, start_emulator])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
