//! Arm64Droid Native HCS & Vulkan GPU Passthrough Daemon.
//!
//! Responsibilities:
//!   1. Probe the host hardware Vulkan runtime (vulkan-1.dll) and create a
//!      real VkDevice + VkQueue (not just an instance, as before).
//!   2. Probe the Microsoft Host Compute System client DLL (honest status).
//!   3. Serve a framed Vulkan-passthrough IPC protocol on 127.0.0.1:6520
//!      for guest clients (reached from the Android guest via the QEMU
//!      slirp gateway at 10.0.2.2:6520).
//!   4. `--selftest` runs every opcode once and prints a report — the fast
//!      feedback loop for verifying the passthrough pipeline on this host.
//!
//! Exit: Ctrl-C / Ctrl-Break / console close triggers a graceful shutdown.

mod ctrl;

use hcs_engine::dispatch::{self, DispatchResult, PROTO_MAGIC_REQ, PROTO_MAGIC_RSP, PROTO_MAX_PAYLOAD};
use hcs_engine::hcs::HcsApi;
use hcs_engine::vulkan_host::{HostVulkanEngine, VK_ERROR_UNKNOWN, VK_SUCCESS};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

fn write_response(stream: &mut TcpStream, opcode: u32, seq: u32, r: &DispatchResult) -> std::io::Result<()> {
    let mut out = Vec::with_capacity(16 + 32 + 4 + r.detail.len() + 4 + r.data.len());
    out.extend_from_slice(&PROTO_MAGIC_RSP.to_le_bytes());
    out.extend_from_slice(&opcode.to_le_bytes());
    out.extend_from_slice(&seq.to_le_bytes());
    out.extend_from_slice(&r.status.to_le_bytes());
    for h in r.handles {
        out.extend_from_slice(&h.to_le_bytes());
    }
    out.extend_from_slice(&(r.detail.len() as u32).to_le_bytes());
    out.extend_from_slice(r.detail.as_bytes());
    // binary data payload (e.g. rendered pixels)
    out.extend_from_slice(&(r.data.len() as u32).to_le_bytes());
    out.extend_from_slice(&r.data);
    stream.write_all(&out)
}

fn handle_client(mut stream: TcpStream, engine: &HostVulkanEngine) -> std::io::Result<()> {
    let mut hdr = [0u8; 16];
    loop {
        // read_exact returns Err(ConnectionReset/Aborted) when the guest
        // disconnects — treat that as a normal end of session.
        if let Err(e) = stream.read_exact(&mut hdr) {
            println!("[*] guest session ended (read error: {e})");
            return Ok(());
        }
        let magic = u32::from_le_bytes(hdr[0..4].try_into().unwrap());
        let opcode = u32::from_le_bytes(hdr[4..8].try_into().unwrap());
        let seq = u32::from_le_bytes(hdr[8..12].try_into().unwrap());
        let plen = u32::from_le_bytes(hdr[12..16].try_into().unwrap());

        if magic != PROTO_MAGIC_REQ {
            eprintln!("[-] bad protocol magic 0x{magic:08X} from guest; dropping connection");
            return Ok(());
        }
        if plen as usize > PROTO_MAX_PAYLOAD {
            let r = DispatchResult::err(VK_ERROR_UNKNOWN, "payload too large");
            let _ = write_response(&mut stream, opcode, seq, &r);
            continue;
        }
        let mut payload = vec![0u8; plen as usize];
        if plen > 0 && stream.read_exact(&mut payload).is_err() {
            return Ok(());
        }

        let r = dispatch::dispatch(engine, opcode, &payload);
        println!(
            "[*] guest opcode {:3} {:<14} -> status {}",
            opcode,
            dispatch::opcode_name(opcode),
            r.status
        );
        if r.status != VK_SUCCESS {
            println!("    reason: {}", r.detail);
        }
        write_response(&mut stream, opcode, seq, &r)?;
    }
}

fn serve_tcp(engine: Arc<HostVulkanEngine>, running: Arc<AtomicBool>) -> std::io::Result<()> {
    let listener = TcpListener::bind("127.0.0.1:6520")?;
    listener.set_nonblocking(true)?;
    println!("[+] GPU Passthrough IPC Daemon online on 127.0.0.1:6520");
    println!("    (Android guest connects to 10.0.2.2:6520 via the slirp gateway)");

    while running.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, addr)) => {
                // Windows accepted sockets inherit the listener's
                // non-blocking mode; restore blocking or the handler sees
                // WSAEWOULDBLOCK (10035) and drops the session.
                if let Err(e) = stream.set_nonblocking(false) {
                    eprintln!("[-] failed to set client socket blocking: {e}");
                }
                println!("[*] guest client connected: {addr}");
                let eng = engine.clone();
                let running = running.clone();
                thread::spawn(move || {
                    let _ = handle_client(stream, &eng);
                    if running.load(Ordering::Relaxed) {
                        println!("[*] guest client disconnected");
                    }
                });
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(10));
            }
            Err(e) => {
                eprintln!("[-] accept error: {e}");
                thread::sleep(Duration::from_millis(50));
            }
        }
    }
    Ok(())
}

/// Run every opcode once against the live host engine and print a report.
/// Exit code 0 when all expected statuses are observed.
fn selftest(engine: &HostVulkanEngine) -> i32 {
    println!("[---] selftest: exercising all passthrough opcodes on the host GPU ---");
    let mut failures = 0;

    let mut check = |label: &str, r: &DispatchResult, expect: i32| {
        let pass = r.status == expect;
        if !pass {
            failures += 1;
        }
        println!(
            "[{}] {:<22} status {:<12} detail: {}",
            if pass { "+" } else { "-" },
            label,
            r.status,
            r.detail
        );
    };

    let r = dispatch::dispatch(engine, dispatch::OP_CREATE_INSTANCE, &[]);
    check("CreateInstance", &r, VK_SUCCESS);

    let r = dispatch::dispatch(engine, dispatch::OP_CREATE_DEVICE, &[]);
    check("CreateDevice", &r, VK_SUCCESS);
    if r.status == VK_SUCCESS && r.handles[0] != 0 && r.handles[1] != 0 {
        println!("    device=0x{:X} queue=0x{:X} family={}", r.handles[0], r.handles[1], r.handles[2]);
    }

    let r = dispatch::dispatch(
        engine,
        dispatch::OP_ALLOCATE_MEMORY,
        &dispatch::payload_allocate_memory(1 << 20, 1), // 1 MiB, host-visible
    );
    check("AllocateMemory", &r, VK_SUCCESS);
    if r.status == VK_SUCCESS {
        println!("    memory=0x{:X} type={}", r.handles[0], r.handles[1]);
    }

    let r = dispatch::dispatch(
        engine,
        dispatch::OP_CREATE_BUFFER,
        &dispatch::payload_create_buffer(64 << 10, 0), // 64 KiB, storage
    );
    check("CreateBuffer", &r, VK_SUCCESS);
    if r.status == VK_SUCCESS {
        println!("    buffer=0x{:X}", r.handles[0]);
    }

    let r = dispatch::dispatch(
        engine,
        dispatch::OP_CREATE_IMAGE,
        &dispatch::payload_create_image(64, 64, 37, 20), // RGBA8_UNORM, sampled|color-attachment
    );
    check("CreateImage", &r, VK_SUCCESS);
    if r.status == VK_SUCCESS {
        println!("    image=0x{:X}", r.handles[0]);
    }

    let r = dispatch::dispatch(engine, dispatch::OP_QUEUE_SUBMIT, &dispatch::payload_u32(0));
    check("QueueSubmit", &r, VK_SUCCESS);

    let r = dispatch::dispatch(engine, dispatch::OP_QUEUE_PRESENT, &dispatch::payload_u32(0));
    // Documented limitation: no WSI surface on the native path.
    check("QueuePresent (no WSI)", &r, hcs_engine::vulkan_host::VK_ERROR_OUT_OF_DATE_KHR);

    let r = dispatch::dispatch(engine, dispatch::OP_DESTROY_DEVICE, &[]);
    check("DestroyDevice", &r, VK_SUCCESS);

    // ---- render pipeline (actual GPU rendering through the dispatcher) ----
    const RW: u32 = 64;
    const RH: u32 = 64;
    let frame_size = (RW * RH * 4) as u64;

    let r = dispatch::dispatch(
        engine,
        dispatch::OP_CREATE_BUFFER,
        &dispatch::payload_create_buffer(frame_size, 0),
    );
    check("RenderCreateBuffer", &r, VK_SUCCESS);
    let buffer_handle = r.handles[0];

    let r = dispatch::dispatch(
        engine,
        dispatch::OP_ALLOCATE_MEMORY,
        &dispatch::payload_allocate_memory(frame_size, 1), // host-visible+coherent
    );
    check("RenderAllocateMemory", &r, VK_SUCCESS);
    let memory_handle = r.handles[0];

    let r = dispatch::dispatch(
        engine,
        dispatch::OP_BIND_RENDER_BUFFER,
        &dispatch::payload_bind_render_buffer(buffer_handle, memory_handle),
    );
    check("BindRenderBuffer", &r, VK_SUCCESS);

    let r = dispatch::dispatch(
        engine,
        dispatch::OP_RENDER_FRAME,
        &dispatch::payload_render_frame(RW, RH),
    );
    check("RenderFrame", &r, VK_SUCCESS);

    let r = dispatch::dispatch(
        engine,
        dispatch::OP_READ_PIXELS,
        &dispatch::payload_read_pixels(frame_size),
    );
    check("ReadPixels", &r, VK_SUCCESS);
    if r.status == VK_SUCCESS {
        let non_zero = r.data.iter().filter(|&&b| b != 0).count();
        println!("    pixels={} bytes, non-zero={} ({}%)",
            r.data.len(), non_zero,
            if r.data.is_empty() { 0 } else { non_zero * 100 / r.data.len() });
    }

    println!("[---] selftest {}: {} failures ---", if failures == 0 { "PASSED" } else { "FAILED" }, failures);
    if failures == 0 { 0 } else { 1 }
}

/// Host-side render: run the full pipeline (create buffer/memory -> bind ->
/// dispatch -> readback) and dump the raw frame to a file.
fn render_to_file(engine: &HostVulkanEngine, width: u32, height: u32, out_path: &str) -> i32 {
    let frame_size = (width as u64) * (height as u64) * 4;
    let r = dispatch::dispatch(
        engine,
        dispatch::OP_CREATE_BUFFER,
        &dispatch::payload_create_buffer(frame_size, 0),
    );
    if r.status != VK_SUCCESS {
        eprintln!("[-] create buffer failed: {}", r.detail);
        return 1;
    }
    let buffer_handle = r.handles[0];

    let r = dispatch::dispatch(
        engine,
        dispatch::OP_ALLOCATE_MEMORY,
        &dispatch::payload_allocate_memory(frame_size, 1),
    );
    if r.status != VK_SUCCESS {
        eprintln!("[-] allocate memory failed: {}", r.detail);
        return 1;
    }
    let memory_handle = r.handles[0];

    let r = dispatch::dispatch(
        engine,
        dispatch::OP_BIND_RENDER_BUFFER,
        &dispatch::payload_bind_render_buffer(buffer_handle, memory_handle),
    );
    if r.status != VK_SUCCESS {
        eprintln!("[-] bind render buffer failed: {}", r.detail);
        return 1;
    }

    let r = dispatch::dispatch(
        engine,
        dispatch::OP_RENDER_FRAME,
        &dispatch::payload_render_frame(width, height),
    );
    if r.status != VK_SUCCESS {
        eprintln!("[-] render frame failed: {}", r.detail);
        return 1;
    }
    println!("[+] rendered compute frame {width}x{height} on host GPU");

    let r = dispatch::dispatch(
        engine,
        dispatch::OP_READ_PIXELS,
        &dispatch::payload_read_pixels(frame_size),
    );
    if r.status != VK_SUCCESS || r.data.len() != frame_size as usize {
        eprintln!("[-] read pixels failed: {} ({} bytes)", r.detail, r.data.len());
        return 1;
    }
    match std::fs::write(out_path, &r.data) {
        Ok(_) => println!("[+] frame written to {out_path} ({} bytes)", r.data.len()),
        Err(e) => {
            eprintln!("[-] failed to write {out_path}: {e}");
            return 1;
        }
    }
    0
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let serve_mode = args.iter().any(|a| a == "--serve");
    let selftest_mode = args.iter().any(|a| a == "--selftest");

    println!("============================================================");
    println!(" Arm64Droid Native HCS & Vulkan GPU Passthrough Daemon");
    println!("============================================================");

    // 1. Probe Host Vulkan hardware driver -> instance + device + queue
    let engine = match HostVulkanEngine::probe() {
        Ok(vk) => {
            println!("[+] Host Hardware Vulkan GPU Passthrough: Active");
            println!("    Device Name   : {}", vk.device_name);
            println!("    API Version   : {}.{}.{}",
                (vk.api_version >> 22) & 0x3ff, (vk.api_version >> 12) & 0x3ff, vk.api_version & 0xfff);
            println!("    Driver Version: {} (0x{:08X})", vk.driver_version_string(), vk.driver_version);
            println!("    Device Handle : 0x{:X}", vk.device as usize);
            println!("    Queue Handle  : 0x{:X} (family {})", vk.queue as usize, vk.queue_family_index);
            Arc::new(vk)
        }
        Err(e) => {
            println!("[-] Host Vulkan probe FAILED: {}", e);
            println!("[-] Native Vulkan passthrough is disabled; only HCS/shared-memory status will be reported.");
            std::process::exit(1);
        }
    };

    // 2. Probe Microsoft HCS Hyper-V Host Compute System
    match HcsApi::load() {
        Ok(api) => {
            println!("[+] Microsoft Host Compute System (HCS v2) Bridge: Ready");
            println!("    {}", api.status_string());
        }
        Err(e) => {
            println!("[-] Microsoft HCS API notice: {}", e);
        }
    }

    if selftest_mode {
        let code = selftest(&engine);
        println!("============================================================");
        std::process::exit(code);
    }

    // --render WxH <out.raw> : render a compute frame on the host GPU and
    // dump the raw pixels; no server needed. e.g. --render 256x256 frame.raw
    if let Some(pos) = args.iter().position(|a| a == "--render") {
        if let Some(size) = args.get(pos + 1) {
            if let Some(out) = args.get(pos + 2) {
                let dims: Vec<&str> = size.split('x').collect();
                if dims.len() == 2 {
                    if let (Ok(w), Ok(h)) = (dims[0].parse::<u32>(), dims[1].parse::<u32>()) {
                        let code = render_to_file(&engine, w, h, out);
                        println!("============================================================");
                        std::process::exit(code);
                    }
                }
            }
        }
        eprintln!("usage: hcs_engine --render WIDTHxHEIGHT <out.raw>");
        std::process::exit(1);
    }

    // --pipelinerecon : diagnostic matrix of pipeline configurations.
    if args.iter().any(|a| a == "--pipelinerecon") {
        println!("[diagnostic] pipeline configuration matrix:");
        for (label, verdict) in hcs_engine::render::RenderPipeline::diagnostic(&engine) {
            println!("  {label:<12} -> {verdict}");
        }
        println!("============================================================");
        std::process::exit(0);
    }

    // 3. Install console ctrl handler (Ctrl-C / Ctrl-Break / close)
    let running = Arc::new(AtomicBool::new(true));
    ctrl::install(Arc::clone(&running));

    // 4. Serve the Vulkan passthrough IPC protocol
    if serve_mode {
        let running_tcp = Arc::clone(&running);
        let engine_tcp = Arc::clone(&engine);
        thread::spawn(move || {
            if let Err(e) = serve_tcp(engine_tcp, running_tcp) {
                eprintln!("[-] TCP listener failed: {}", e);
            }
        });
    } else {
        println!("[*] Not serving (no --serve). Run with --serve to accept guest connections.");
    }

    // 6. Wait for shutdown request
    while running.load(Ordering::Relaxed) {
        thread::sleep(Duration::from_millis(200));
    }
    println!("[+] Daemon shutting down cleanly. Bye.");
    println!("============================================================");
}