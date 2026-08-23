use windows_sys::Win32::Foundation::HMODULE;
use windows_sys::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};

fn to_wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

type InitVMFn = unsafe extern "C" fn(vm_index: i32, out_handle: *mut *mut std::ffi::c_void) -> i32;
type ConfigVMFn = unsafe extern "C" fn(handle: *mut std::ffi::c_void, config_json: *const u16) -> i32;
type StartVMFn = unsafe extern "C" fn(handle: *mut std::ffi::c_void) -> i32;
type StopVMFn = unsafe extern "C" fn(handle: *mut std::ffi::c_void) -> i32;
type ReleaseVMFn = unsafe extern "C" fn(handle: *mut std::ffi::c_void) -> i32;

fn main() {
    println!("=== Testing Native ARM64 HCS VM Initialization ===");
    let dll_dir = r"C:\Program Files\Netease\MuMuPlayer\shell";
    let dll_path = format!(r"{}\nemu-hcs.dll", dll_dir);
    
    unsafe {
        let h_module: HMODULE = LoadLibraryW(to_wide(&dll_path).as_ptr());
        if h_module.is_null() {
            println!("Failed to load nemu-hcs.dll!");
            return;
        }

        type InitVMFn = unsafe extern "C" fn(path: *const u16, callback: *const std::ffi::c_void) -> *mut std::ffi::c_void;
        type ConfigVMFn = unsafe extern "C" fn(handle: *mut std::ffi::c_void, callback: *const std::ffi::c_void) -> i32;
        type StartVMFn = unsafe extern "C" fn(handle: *mut std::ffi::c_void) -> i32;

        let init_vm: InitVMFn = std::mem::transmute(GetProcAddress(h_module, b"InitVM\0".as_ptr()).unwrap());
        let config_vm: ConfigVMFn = std::mem::transmute(GetProcAddress(h_module, b"ConfigVM\0".as_ptr()).unwrap());
        let start_vm: StartVMFn = std::mem::transmute(GetProcAddress(h_module, b"StartVM\0".as_ptr()).unwrap());

        let get_last_error: unsafe extern "C" fn() -> *const u16 = std::mem::transmute(GetProcAddress(h_module, b"GetLastVMError\0".as_ptr()).unwrap());

        let vm_dir = to_wide(r"C:\Program Files\Netease\MuMuPlayer\vms\vm0.madoa");
        println!("Calling InitVM with directory: C:\\Program Files\\Netease\\MuMuPlayer\\vms\\vm0.madoa...");
        let vm_handle = init_vm(vm_dir.as_ptr(), std::ptr::null());
        println!("InitVM returned handle: {:p}", vm_handle);
        
        let err_ptr = get_last_error();
        if !err_ptr.is_null() {
            let mut len = 0;
            while *err_ptr.add(len) != 0 { len += 1; }
            let err_slice = std::slice::from_raw_parts(err_ptr, len);
            let err_str = String::from_utf16_lossy(err_slice);
            println!("GetLastVMError: '{}'", err_str);
        }
    }
}
