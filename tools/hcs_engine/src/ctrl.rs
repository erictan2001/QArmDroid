//! Graceful shutdown on console control events (Ctrl-C / Ctrl-Break /
//! console close) without pulling in extra dependencies — a raw
//! SetConsoleCtrlHandler through kernel32, matching the crate's existing
//! hand-rolled Windows FFI style.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

const CTRL_C_EVENT: u32 = 0;
const CTRL_BREAK_EVENT: u32 = 1;
const CTRL_CLOSE_EVENT: u32 = 2;

type HandlerRoutine = unsafe extern "system" fn(u32) -> i32;

unsafe extern "system" {
    fn SetConsoleCtrlHandler(handler: Option<HandlerRoutine>, add: i32) -> i32;
}

static FLAG: AtomicBool = AtomicBool::new(false);

/// Returns whether a shutdown has been requested.
pub fn stop_requested() -> bool {
    FLAG.load(Ordering::Relaxed)
}

unsafe extern "system" fn handler(event: u32) -> i32 {
    match event {
        CTRL_C_EVENT | CTRL_BREAK_EVENT | CTRL_CLOSE_EVENT => {
            eprintln!("[*] shutdown requested via console event {event}");
            FLAG.store(true, Ordering::Relaxed);
            1 // handled; keep the default handler from terminating us mid-cleanup
        }
        _ => 0, // not our event
    }
}

/// Install the console control handler and marshal the request into
/// `running` so the daemon loop can exit cleanly.
pub fn install(running: Arc<AtomicBool>) {
    unsafe {
        let installed = SetConsoleCtrlHandler(Some(handler), 1);
        if installed == 0 {
            eprintln!("[-] SetConsoleCtrlHandler failed; Ctrl-C will force-kill");
        }
    }
    // The handler only flips the static flag; a poller thread forwards it to
    // the Arc so the main loop observes it.
    std::thread::spawn(move || {
        loop {
            if stop_requested() {
                running.store(false, Ordering::Relaxed);
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
    });
}