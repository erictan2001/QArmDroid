//! Minimal Microsoft Host Compute System (HCS v2) probe.
//!
//! On Windows the v2 HCS API lives in `vmcompute.dll` (the Host Compute
//! Service client). Older builds also ship the threaded-operation helpers
//! (`HcsCreateOperation`/`HcsCloseOperation`); current builds (including
//! this Windows ARM64 host) drop them and perform *synchronous* calls by
//! passing a NULL `HCS_OPERATION` to `HcsCreateComputeSystem` /
//! `HcsStartComputeSystem`.
//!
//! NOTE: this module *probes* availability only. Actually hosting the
//! Android VM through HCS (instead of the QEMU/WHPX path in launch.ps1) is
//! a separate, much larger integration; the daemon reports readiness so the
//! launcher can log an honest status.

use std::ffi::c_void;
use std::ptr::null_mut;

pub type HRESULT = i32;
pub type HANDLE = *mut c_void;
pub type HcsSystem = *mut c_void;
pub type HcsOperation = *mut c_void;

/// Synchronous HCS v2 binding: `operation` parameters are always NULL,
/// which the API defines as "perform synchronously" (the modern ABI no
/// longer exports HcsCreateOperation on this build).
#[repr(C)]
pub struct HcsApi {
    module: HANDLE,
    /// Optional on current builds; present on older Windows versions.
    pub hcs_create_operation: Option<unsafe extern "system" fn(
        callback: *const c_void,
        context: *const c_void,
    ) -> HcsOperation>,
    /// Optional on current builds; present on older Windows versions.
    pub hcs_close_operation: Option<unsafe extern "system" fn(operation: HcsOperation)>,
    pub hcs_create_compute_system: unsafe extern "system" fn(
        id: *const u16,
        configuration: *const u16,
        operation: HcsOperation,
        security_descriptor: *const c_void,
        compute_system: *mut HcsSystem,
    ) -> HRESULT,
    pub hcs_start_compute_system: unsafe extern "system" fn(
        compute_system: HcsSystem,
        operation: HcsOperation,
        options: *const u16,
    ) -> HRESULT,
    pub hcs_close_compute_system: unsafe extern "system" fn(compute_system: HcsSystem),
}

unsafe impl Send for HcsApi {}
unsafe impl Sync for HcsApi {}

unsafe extern "system" {
    fn LoadLibraryW(lpLibFileName: *const u16) -> HANDLE;
    fn GetProcAddress(hModule: HANDLE, lpProcName: *const u8) -> *mut c_void;
    fn FreeLibrary(hLibModule: HANDLE) -> i32;
    fn GetLastError() -> u32;
}

fn to_wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

impl HcsApi {
    pub fn load() -> Result<Self, String> {
        unsafe {
            // Try both DLL names; keep track of what failed for a useful error.
            let mut module: HANDLE = null_mut();
            let mut loaded_name: Option<&'static str> = None;
            let mut tried: Vec<String> = Vec::new();
            for lib in ["vmcompute.dll", "computecore.dll"] {
                let name = to_wide(lib);
                module = LoadLibraryW(name.as_ptr());
                if !module.is_null() {
                    loaded_name = Some(lib);
                    break;
                }
                tried.push(format!("{lib} (win32 error {})", GetLastError()));
            }
            if module.is_null() {
                return Err(format!(
                    "Could not load HCS client DLL; tried: {}",
                    tried.join(", ")
                ));
            }
            let loaded_name = loaded_name.unwrap();

            let get = |name: &[u8]| -> *mut c_void {
                GetProcAddress(module, name.as_ptr())
            };

            // Required: synchronous system-lifecycle exports.
            let mut missing = Vec::new();
            let p_create_sys = get(b"HcsCreateComputeSystem\0");
            let p_start_sys = get(b"HcsStartComputeSystem\0");
            let p_close_sys = get(b"HcsCloseComputeSystem\0");
            for (label, p) in [
                ("HcsCreateComputeSystem", p_create_sys),
                ("HcsStartComputeSystem", p_start_sys),
                ("HcsCloseComputeSystem", p_close_sys),
            ] {
                if p.is_null() {
                    missing.push(label.to_string());
                }
            }
            if !missing.is_empty() {
                FreeLibrary(module);
                return Err(format!(
                    "HCS DLL '{loaded_name}' is missing required exports: {}",
                    missing.join(", ")
                ));
            }

            // Optional: threaded-operation helpers (absent on current builds).
            let p_create_op = get(b"HcsCreateOperation\0");
            let p_close_op = get(b"HcsCloseOperation\0");
            let hcs_create_operation = if p_create_op.is_null() {
                None
            } else {
                Some(std::mem::transmute(p_create_op))
            };
            let hcs_close_operation = if p_close_op.is_null() {
                None
            } else {
                Some(std::mem::transmute(p_close_op))
            };

            Ok(Self {
                module,
                hcs_create_operation,
                hcs_close_operation,
                hcs_create_compute_system: std::mem::transmute(p_create_sys),
                hcs_start_compute_system: std::mem::transmute(p_start_sys),
                hcs_close_compute_system: std::mem::transmute(p_close_sys),
            })
        }
    }

    /// Human-readable readiness summary for the daemon banner.
    pub fn status_string(&self) -> String {
        let mut s = format!("HCS client 'vmcompute' loaded with synchronous v2 API");
        if self.hcs_create_operation.is_some() {
            s.push_str(" + threaded-operation helpers");
        } else {
            s.push_str(" (threaded-operation helpers not exported by this build)");
        }
        s
    }
}

impl Drop for HcsApi {
    fn drop(&mut self) {
        if !self.module.is_null() {
            unsafe { FreeLibrary(self.module); }
        }
    }
}