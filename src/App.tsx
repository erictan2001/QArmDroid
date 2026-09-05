import { useEffect, useRef, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import RFB from "@novnc/novnc";
import "./App.css";

interface EmulatorStatus {
  running: boolean;
  vnc_ready: boolean;
  adb_ready: boolean;
  boot_completed: boolean;
  scrcpy_running: boolean;
}

interface ImageConfig {
  installed: boolean;
  provisioned: boolean;
  disk_size_gb: number;
  fs_format: string;
  runtime_root: string;
  qemu_present: boolean;
  qemu_path: string;
  scrcpy_present: boolean;
  scrcpy_path: string;
  adb_present: boolean;
  adb_path: string;
  python_present: boolean;
  kernel_present: boolean;
  super_present: boolean;
  disk_present: boolean;
  cores: number;
  memory_gb: number;
  gpu_mode: string;
  close_on_exit: boolean;
  tablet_mode: boolean;
  gesture_nav: boolean;
}

interface ProvisionProgress {
  percent: number;
  stage: string;
  message: string;
  done: boolean;
  error: boolean;
}

export function App() {
  const screenRef = useRef<HTMLDivElement | null>(null);
  const rfbRef = useRef<RFB | null>(null);
  const isPointerDownRef = useRef<boolean>(false);

  const [status, setStatus] = useState<EmulatorStatus>({
    running: false,
    vnc_ready: false,
    adb_ready: false,
    boot_completed: false,
    scrcpy_running: false,
  });
  const [displayMode, setDisplayMode] = useState<"scrcpy" | "embedded" | "sdl">("embedded");
  const [connecting, setConnecting] = useState<boolean>(false);
  const [connected, setConnected] = useState<boolean>(false);
  const [logMsg, setLogMsg] = useState<string>("QArmDroid ready. Click 'Launch Emulator' to start Android 16.");
  const [inputText, setInputText] = useState("");
  const [touchFeedback, setTouchFeedback] = useState<{ x: number; y: number; visible: boolean }>({
    x: 0,
    y: 0,
    visible: false,
  });

  // --- Settings & Provisioning state ---
  const [imageConfig, setImageConfig] = useState<ImageConfig>({
    installed: false,
    provisioned: false,
    disk_size_gb: 16,
    fs_format: "ext4",
    runtime_root: "",
    qemu_present: false,
    qemu_path: "",
    scrcpy_present: false,
    scrcpy_path: "",
    adb_present: false,
    adb_path: "",
    python_present: false,
    kernel_present: false,
    super_present: false,
    disk_present: false,
    cores: 6,
    memory_gb: 6,
    gpu_mode: "basic",
    close_on_exit: true,
    tablet_mode: false,
    gesture_nav: true,
  });
  const [showSettings, setShowSettings] = useState<boolean>(false);
  const [savePopup, setSavePopup] = useState<{ visible: boolean; message: string; isError?: boolean }>({
    visible: false,
    message: "",
  });
  const [confirmRebuild, setConfirmRebuild] = useState<{
    visible: boolean;
    force: boolean;
    targetSizeGb: number;
    currentSizeGb: number;
    fsFormat: string;
    isShrink: boolean;
    isExpand: boolean;
  }>({
    visible: false,
    force: false,
    targetSizeGb: 16,
    currentSizeGb: 16,
    fsFormat: "ext4",
    isShrink: false,
    isExpand: false,
  });
  const [provision, setProvision] = useState<ProvisionProgress>({
    percent: 0,
    stage: "",
    message: "",
    done: false,
    error: false,
  });
  const [provisioning, setProvisioning] = useState<boolean>(false);
  const [settingsDraft, setSettingsDraft] = useState<{
    sizeGb: number;
    fs: string;
    cores: number;
    memoryGb: number;
    gpuMode: string;
    closeOnExit: boolean;
    tabletMode: boolean;
    gestureNav: boolean;
  }>({
    sizeGb: 16,
    fs: "ext4",
    cores: 6,
    memoryGb: 6,
    gpuMode: "basic",
    closeOnExit: true,
    tabletMode: false,
    gestureNav: true,
  });

  const loadImageConfig = async () => {
    try {
      const cfg = await invoke<ImageConfig>("get_image_config");
      setImageConfig(cfg);
      setSettingsDraft({
        sizeGb: cfg.disk_size_gb || 16,
        fs: cfg.fs_format || "ext4",
        cores: cfg.cores || 6,
        memoryGb: cfg.memory_gb || 6,
        gpuMode: cfg.gpu_mode || "basic",
        closeOnExit: cfg.close_on_exit ?? true,
        tabletMode: cfg.tablet_mode ?? false,
        gestureNav: cfg.gesture_nav ?? true,
      });
      // First run and not yet provisioned -> open settings gate automatically.
      if (!cfg.provisioned && !showSettings) {
        setShowSettings(true);
      }
    } catch {
      // Dev repo without the command: assume provisioned to not block launch.
      setImageConfig((c) => ({ ...c, provisioned: true }));
    }
  };

  // Check emulator status periodically
  const checkStatus = async () => {
    try {
      const res = await invoke<EmulatorStatus>("get_emulator_status");
      setStatus(res);
      return res;
    } catch {
      return { running: false, vnc_ready: false, adb_ready: false, boot_completed: false, scrcpy_running: false };
    }
  };

  useEffect(() => {
    loadImageConfig();
    const timer = setInterval(() => {
      checkStatus();
    }, 1500);
    checkStatus();
    return () => clearInterval(timer);
  }, []);

  // Listen for real-time provisioning progress from the Rust host.
  useEffect(() => {
    const unlisten = listen<ProvisionProgress>("provision-progress", (event) => {
      const p = event.payload;
      setProvision(p);
      if (!p.done && !p.error) setProvisioning(true);
      if (p.done) {
        setProvisioning(false);
        if (!p.error) {
          loadImageConfig();
        }
      }
    });
    return () => {
      unlisten.then((fn) => fn()).catch(() => {});
    };
  }, []);

  const handleLaunchScrcpy = async () => {
    try {
      setLogMsg("Launching Scrcpy mirror window...");
      const msg = await invoke<string>("launch_scrcpy");
      setLogMsg(msg);
    } catch (e) {
      setLogMsg(`Scrcpy launch error: ${e}`);
    }
  };

  // Connect to VNC WebSocket with zero-compression, ultra-low latency settings
  const connectVNC = () => {
    if (!screenRef.current) return;
    if (rfbRef.current) {
      try {
        rfbRef.current.disconnect();
      } catch {}
      rfbRef.current = null;
    }

    setConnecting(true);
    setLogMsg("Connecting to ultra-low latency display stream...");

    try {
      const rfb = new RFB(screenRef.current, "ws://127.0.0.1:5901");
      
      // Performance optimizations: disable compression overhead over localhost
      rfb.qualityLevel = 9;       // Maximum quality, no lossy JPEG artifacts
      rfb.compressionLevel = 0;   // 0 zlib compression (instant blit over localhost memory)
      rfb.scaleViewport = true;
      rfb.resizeSession = false;
      rfb.clipViewport = false;
      rfb.focusOnClick = true;
      // viewOnly=false: noVNC sends pointer/keyboard events over VNC to
      // QEMU's USB HID devices (usb-tablet/usb-kbd attached in embedded
      // mode). This is the RELIABLE input path and needs no guest daemon.
      // (The old viewOnly=true + custom touch daemon silently did nothing
      // when the daemon wasn't deployed -> touch appeared broken.)
      rfb.viewOnly = false;
      rfb.background = "#0f172a";
      // Blue dot cursor: noVNC hides the OS cursor over the canvas and draws
      // its own dot at the pointer location, so the user always sees where the
      // next tap will land (Android-emulator style touch indicator). The
      // property exists at runtime (core/rfb.js) but is missing from the
      // package's loose typings, so cast to a minimal shape.
      (rfb as RFB & { showDotCursor: boolean }).showDotCursor = true;

      rfb.addEventListener("connect", () => {
        setConnecting(false);
        setConnected(true);
        setLogMsg("Connected to Android display — VNC input active");

        // Native listeners on the RFB canvas: handle both PointerEvent and MouseEvent
        // so the blue touch dot always follows the cursor (hover, click, and drag).
        const canvas = screenRef.current?.querySelector("canvas");
        if (canvas && !(canvas as any).__qarm_ripple_bound) {
          (canvas as any).__qarm_ripple_bound = true;
          const onMove = (e: Event) => {
            const me = e as MouseEvent;
            const coords = getGuestCoords(me.clientX, me.clientY);
            if (coords) {
              setTouchFeedback({
                x: coords.screenX,
                y: coords.screenY,
                visible: true,
              });
            }
          };
          const onDown = (e: Event) => {
            const me = e as MouseEvent;
            const coords = getGuestCoords(me.clientX, me.clientY);
            if (coords) {
              isPointerDownRef.current = true;
              setTouchFeedback({ x: coords.screenX, y: coords.screenY, visible: true });
            }
          };
          const onUp = (e: Event) => {
            isPointerDownRef.current = false;
            const me = e as MouseEvent;
            const coords = getGuestCoords(me.clientX, me.clientY);
            if (coords) {
              setTouchFeedback({ x: coords.screenX, y: coords.screenY, visible: true });
            }
          };
          canvas.addEventListener("pointermove", onMove, { capture: true });
          canvas.addEventListener("mousemove", onMove, { capture: true });
          canvas.addEventListener("pointerdown", onDown, { capture: true });
          canvas.addEventListener("mousedown", onDown, { capture: true });
          canvas.addEventListener("pointerup", onUp, { capture: true });
          canvas.addEventListener("mouseup", onUp, { capture: true });

          (canvas as any).__qarm_ripple_cleanup = () => {
            canvas.removeEventListener("pointermove", onMove, { capture: true });
            canvas.removeEventListener("mousemove", onMove, { capture: true });
            canvas.removeEventListener("pointerdown", onDown, { capture: true });
            canvas.removeEventListener("mousedown", onDown, { capture: true });
            canvas.removeEventListener("pointerup", onUp, { capture: true });
            canvas.removeEventListener("mouseup", onUp, { capture: true });
          };
        }
      });

      rfb.addEventListener("disconnect", (e: any) => {
        setConnecting(false);
        setConnected(false);
        // Clean up native canvas listeners
        const canvas = screenRef.current?.querySelector("canvas");
        if (canvas && (canvas as any).__qarm_ripple_cleanup) {
          (canvas as any).__qarm_ripple_cleanup();
          delete (canvas as any).__qarm_ripple_cleanup;
        }
        setConnecting(false);
        setConnected(false);
        rfbRef.current = null;
        setLogMsg(e?.detail?.clean ? "Display stream closed" : "Display disconnected");
      });

      rfb.addEventListener("credentialsrequired", () => {
        setConnecting(false);
      });

      rfbRef.current = rfb;
    } catch (err) {
      setConnecting(false);
      setConnected(false);
      setLogMsg(`Connection failed: ${err}`);
    }
  };

  const [optimized, setOptimized] = useState(false);

  // Auto-connect when VNC port becomes ready in embedded mode
  useEffect(() => {
    if (displayMode === "embedded" && status.vnc_ready && !connected && !connecting && !rfbRef.current) {
      connectVNC();
    }
  }, [status.vnc_ready, displayMode, connected, connecting]);

  // Auto-launch Scrcpy when Android completes booting in Scrcpy mode
  useEffect(() => {
    if (status.boot_completed && displayMode === "scrcpy" && !status.scrcpy_running) {
      handleLaunchScrcpy();
    }
  }, [status.boot_completed, displayMode, status.scrcpy_running]);

  // Auto-optimize animations and settings once ADB becomes available
  useEffect(() => {
    if (status.adb_ready && !optimized) {
      invoke("optimize_performance").catch(() => {});
      invoke("deploy_touch_daemon")
        .then(() => setLogMsg("Touch daemon active — 1:1 direct input enabled"))
        .catch(() => setLogMsg("Touch daemon not available, using ADB fallback"));
      setOptimized(true);
    } else if (!status.adb_ready) {
      setOptimized(false);
    }
  }, [status.adb_ready, optimized]);

  // Calculate pixel-exact guest coordinates accounting for aspect-ratio letterboxing
  const getGuestCoords = useCallback((clientX: number, clientY: number) => {
    const canvas = screenRef.current?.querySelector("canvas");
    if (!canvas) return null;
    const rect = canvas.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return null;

    // Constrain within actual rendered canvas bounds
    const clampedX = Math.max(rect.left, Math.min(rect.right, clientX));
    const clampedY = Math.max(rect.top, Math.min(rect.bottom, clientY));

    const scaleX = 1280 / rect.width;
    const scaleY = 800 / rect.height;

    const x = Math.max(0, Math.min(1279, Math.round((clampedX - rect.left) * scaleX)));
    const y = Math.max(0, Math.min(799, Math.round((clampedY - rect.top) * scaleY)));

    return { x, y, screenX: clampedX, screenY: clampedY };
  }, []);

  // Global capture-phase cursor tracking: ensures the blue touch dot follows the
  // cursor throughout any hover or drag gesture, even when noVNC's full-screen
  // capture element (#noVNC_mouse_capture_elem, z-index 10000) intercepts events.
  useEffect(() => {
    if (displayMode !== "embedded") return;

    const onGlobalMove = (e: MouseEvent | PointerEvent) => {
      const coords = getGuestCoords(e.clientX, e.clientY);
      if (coords) {
        setTouchFeedback({
          x: coords.screenX,
          y: coords.screenY,
          visible: true,
        });
      } else if (!isPointerDownRef.current) {
        setTouchFeedback((prev) => (prev.visible ? { ...prev, visible: false } : prev));
      }
    };

    const onGlobalUp = (e: MouseEvent | PointerEvent) => {
      isPointerDownRef.current = false;
      const coords = getGuestCoords(e.clientX, e.clientY);
      if (coords) {
        setTouchFeedback({ x: coords.screenX, y: coords.screenY, visible: true });
      } else {
        setTouchFeedback((prev) => (prev.visible ? { ...prev, visible: false } : prev));
      }
    };

    window.addEventListener("pointermove", onGlobalMove, { capture: true, passive: true });
    window.addEventListener("mousemove", onGlobalMove, { capture: true, passive: true });
    window.addEventListener("pointerup", onGlobalUp, { capture: true });
    window.addEventListener("mouseup", onGlobalUp, { capture: true });
    window.addEventListener("pointercancel", onGlobalUp, { capture: true });

    return () => {
      window.removeEventListener("pointermove", onGlobalMove, { capture: true });
      window.removeEventListener("mousemove", onGlobalMove, { capture: true });
      window.removeEventListener("pointerup", onGlobalUp, { capture: true });
      window.removeEventListener("mouseup", onGlobalUp, { capture: true });
      window.removeEventListener("pointercancel", onGlobalUp, { capture: true });
    };
  }, [displayMode, getGuestCoords]);

  const handlePointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    // Embedded mode: noVNC (viewOnly=false) relays pointer events over VNC
    // to the guest's USB tablet. Do NOT dispatch via the touch daemon (would
    // double-input). Keep the blue touch dot visible and tracking.
    if (displayMode === "embedded") {
      const coords = getGuestCoords(e.clientX, e.clientY);
      if (coords) {
        isPointerDownRef.current = true;
        setTouchFeedback({ x: coords.screenX, y: coords.screenY, visible: true });
      }
      return;
    }
    if (!connected || e.button !== 0) return;
    const coords = getGuestCoords(e.clientX, e.clientY);
    if (!coords) return;

    try {
      e.currentTarget.setPointerCapture(e.pointerId);
    } catch {}

    isPointerDownRef.current = true;
    setTouchFeedback({ x: coords.screenX, y: coords.screenY, visible: true });
    invoke("send_motion_down", { x: coords.x, y: coords.y }).catch(() => {});
  };

  const handlePointerMove = (e: React.PointerEvent<HTMLDivElement>) => {
    const coords = getGuestCoords(e.clientX, e.clientY);
    if (displayMode === "embedded") {
      if (coords) {
        setTouchFeedback({ x: coords.screenX, y: coords.screenY, visible: true });
      } else if (!isPointerDownRef.current) {
        setTouchFeedback((prev) => (prev.visible ? { ...prev, visible: false } : prev));
      }
      return;
    }
    if (!isPointerDownRef.current) return;
    if (!coords) return;

    setTouchFeedback({ x: coords.screenX, y: coords.screenY, visible: true });
    invoke("send_motion_move", { x: coords.x, y: coords.y }).catch(() => {});
  };

  const handlePointerUp = (e: React.PointerEvent<HTMLDivElement>) => {
    if (displayMode === "embedded") {
      isPointerDownRef.current = false;
      const coords = getGuestCoords(e.clientX, e.clientY);
      if (coords) {
        setTouchFeedback({ x: coords.screenX, y: coords.screenY, visible: true });
      } else {
        setTouchFeedback((prev) => (prev.visible ? { ...prev, visible: false } : prev));
      }
      return;
    }
    if (!isPointerDownRef.current) return;
    isPointerDownRef.current = false;
    setTouchFeedback((prev) => ({ ...prev, visible: false }));

    const coords = getGuestCoords(e.clientX, e.clientY);
    const x = coords ? coords.x : 0;
    const y = coords ? coords.y : 0;

    invoke("send_motion_up", { x, y }).catch(() => {});
    try {
      e.currentTarget.releasePointerCapture(e.pointerId);
    } catch {}
  };

  const handlePointerLeave = () => {
    if (displayMode === "embedded" && !isPointerDownRef.current) {
      setTouchFeedback((prev) => (prev.visible ? { ...prev, visible: false } : prev));
    }
  };

  const handleContextMenu = (e: React.MouseEvent) => {
    e.preventDefault();
    // Right-click triggers Android Back button
    sendKey("4");
  };

  const handleStart = async () => {
    if (!imageConfig.provisioned) {
      setLogMsg("Install the Android image first in Settings.");
      setShowSettings(true);
      return;
    }
    setLogMsg(`Launching Android VM in ${displayMode} mode...`);
    try {
      const msg = await invoke<string>("start_emulator", { displayMode });
      setLogMsg(msg);
      // Poll for readiness
      setTimeout(async () => {
        const s = await checkStatus();
        if (displayMode === "embedded" && s.vnc_ready) connectVNC();
      }, 1500);
    } catch (e) {
      setLogMsg(`Failed to launch: ${e}`);
    }
  };

  // --- Settings & Runtime handlers ---
  const openSettings = async () => {
    await loadImageConfig();
    setShowSettings(true);
  };

  const saveSettingsDraft = async () => {
    try {
      const cfg = await invoke<ImageConfig>("save_image_config", {
        diskSizeGb: settingsDraft.sizeGb,
        fsFormat: settingsDraft.fs,
        cores: settingsDraft.cores,
        memoryGb: settingsDraft.memoryGb,
        gpuMode: settingsDraft.gpuMode,
        closeOnExit: settingsDraft.closeOnExit,
        tabletMode: settingsDraft.tabletMode,
        gestureNav: settingsDraft.gestureNav,
      });
      setImageConfig(cfg);
      setLogMsg("Settings saved successfully.");
      setSavePopup({
        visible: true,
        message: `• Partition Size: ${cfg.disk_size_gb} GB (${cfg.fs_format})\n• vCPU Cores: ${cfg.cores} Cores\n• RAM Memory: ${cfg.memory_gb} GB\n• GPU Acceleration: ${cfg.gpu_mode}\n• System Navigation: ${cfg.gesture_nav ? "Gesture Navigation (Edge-to-Edge)" : "3-Button Navigation"}\n• UI Form Factor: ${cfg.tablet_mode ? "Tablet Mode (213 dpi / 600+ dp)" : "Standard Phone Mode (240 dpi)"}\n• Close on Exit: ${cfg.close_on_exit ? "Enabled (stop emulator)" : "Disabled (keep running)"}\n• Display Engine: ${displayMode}`,
        isError: false,
      });
    } catch (e) {
      setLogMsg(`Could not save settings: ${e}`);
      setSavePopup({
        visible: true,
        message: `Failed to save settings: ${e}`,
        isError: true,
      });
    }
  };

  const handleOpenRuntimeFolder = async () => {
    try {
      await invoke("open_runtime_folder");
    } catch (e) {
      setLogMsg(`Could not open runtime folder: ${e}`);
    }
  };

  const handleOptimize = async () => {
    try {
      const res = await invoke<string>("optimize_performance");
      setLogMsg(res);
    } catch (e) {
      setLogMsg(`Optimize error: ${e}`);
    }
  };

  const handleProvision = async (force: boolean, rebuildDisk: boolean = false) => {
    if (status.running) {
      setLogMsg("Cannot rebuild disk while emulator is running. Please stop the emulator first.");
      setSavePopup({
        visible: true,
        message: "The emulator is currently running. Please click 'Stop Emulator' before rebuilding or modifying the virtual disk.",
        isError: true,
      });
      return;
    }
    // Persist the chosen settings before building.
    await saveSettingsDraft();
    setProvisioning(true);
    setProvision({
      percent: 0,
      stage: "Starting",
      message: rebuildDisk ? "Rebuilding Android virtual disk image..." : "Preparing to install the Android image...",
      done: false,
      error: false,
    });
    try {
      const msg = await invoke<string>("provision_image", {
        force,
        rebuildDisk,
        diskSizeGb: settingsDraft.sizeGb,
        fsFormat: settingsDraft.fs,
      });
      setLogMsg(msg);
    } catch (e) {
      setLogMsg(`Provisioning error: ${e}`);
      setProvisioning(false);
    }
  };

  const requestRebuild = (force: boolean) => {
    if (status.running) {
      setLogMsg("Cannot rebuild disk while emulator is running. Please stop the emulator first.");
      setSavePopup({
        visible: true,
        message: "The emulator is currently running. Please click 'Stop Emulator' before rebuilding or modifying the virtual disk.",
        isError: true,
      });
      return;
    }
    if (imageConfig.provisioned) {
      setConfirmRebuild({
        visible: true,
        force,
        targetSizeGb: settingsDraft.sizeGb,
        currentSizeGb: imageConfig.disk_size_gb,
        fsFormat: settingsDraft.fs,
        isShrink: settingsDraft.sizeGb < imageConfig.disk_size_gb,
        isExpand: settingsDraft.sizeGb > imageConfig.disk_size_gb,
      });
    } else {
      handleProvision(force, true);
    }
  };

  const closeSettings = () => {
    if (provisioning) return; // don't allow closing mid-build
    setShowSettings(false);
  };

  const handleStop = async () => {
    setLogMsg("Stopping emulator...");
    if (rfbRef.current) {
      try {
        rfbRef.current.disconnect();
      } catch {}
      rfbRef.current = null;
    }
    setConnected(false);
    try {
      const msg = await invoke<string>("stop_emulator");
      setLogMsg(msg);
      setTimeout(checkStatus, 1000);
    } catch (e) {
      setLogMsg(`Stop error: ${e}`);
    }
  };

  // Key control is ready if ADB has connected to the guest OR if embedded VNC is actively connected
  const isKeyControlReady = status.adb_ready || (displayMode === "embedded" && connected);

  const sendKey = async (key: string) => {
    // 1. If ADB is connected, dispatch exact Android key event directly
    if (status.adb_ready) {
      try {
        await invoke("send_adb_key", { key });
        return;
      } catch (e) {
        console.warn("ADB key failed, trying VNC fallback:", e);
      }
    }

    // 2. In embedded mode, send direct hardware keysym via noVNC to QEMU's usb-kbd
    if (displayMode === "embedded" && rfbRef.current) {
      const keyMap: Record<string, { keysym: number; code: string }> = {
        "4": { keysym: 0xff1b, code: "Escape" },          // Back -> Escape
        "3": { keysym: 0xff50, code: "Home" },            // Home -> Home
        "187": { keysym: 0xffbe, code: "F1" },            // Recents / App Switch -> F1
        "24": { keysym: 0x1008ff13, code: "AudioVolumeUp" },
        "25": { keysym: 0x1008ff11, code: "AudioVolumeDown" },
        "26": { keysym: 0x1008ff2a, code: "Power" },
      };
      const mapped = keyMap[key];
      if (mapped) {
        try {
          (rfbRef.current as any).sendKey(mapped.keysym, mapped.code);
          return;
        } catch (err) {
          console.error("VNC sendKey error:", err);
        }
      }
    }

    // 3. Fallback: invoke send_adb_key (Rust backend auto-connects to 127.0.0.1:5555 if needed)
    try {
      await invoke("send_adb_key", { key });
    } catch (e) {
      setLogMsg(`Key event error: ${e}`);
    }
  };

  const handleSendText = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!inputText.trim()) return;
    const textToSend = inputText;
    setInputText("");

    // Try ADB input text first if ADB is ready
    if (status.adb_ready) {
      try {
        const escaped = textToSend.replace(/ /g, "%s");
        await invoke("send_adb_text", { text: escaped });
        return;
      } catch (e) {
        console.warn("ADB text error, trying VNC typing:", e);
      }
    }

    // Embedded mode: forward characters over VNC directly to guest
    if (displayMode === "embedded" && rfbRef.current) {
      try {
        for (let i = 0; i < textToSend.length; i++) {
          const char = textToSend[i];
          const code = char.charCodeAt(0);
          (rfbRef.current as any).sendKey(code, `Key${char.toUpperCase()}`);
        }
        (rfbRef.current as any).sendKey(0xff0d, "Enter");
        return;
      } catch (err) {
        console.error("VNC sendText error:", err);
      }
    }

    // Fallback: invoke send_adb_text
    try {
      const escaped = textToSend.replace(/ /g, "%s");
      await invoke("send_adb_text", { text: escaped });
    } catch (e) {
      setLogMsg(`Send text error: ${e}`);
    }
  };

  // Global physical keyboard shortcuts (Esc = Back, F1 = Recents, F3/Home = Home)
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      // Don't intercept if user is typing in an HTML input or textarea
      const target = e.target as HTMLElement | null;
      if (
        target &&
        (target.tagName === "INPUT" ||
          target.tagName === "TEXTAREA" ||
          target.isContentEditable)
      ) {
        return;
      }

      if (!isKeyControlReady) return;

      if (e.key === "Escape") {
        e.preventDefault();
        sendKey("4"); // Android Back
      } else if (e.key === "F1" || e.key === "F2") {
        e.preventDefault();
        sendKey("187"); // Android App Switch / Recents
      } else if (e.key === "F3" || (e.altKey && e.key === "Home")) {
        e.preventDefault();
        sendKey("3"); // Android Home
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [isKeyControlReady, status.adb_ready, displayMode, connected]);

  return (
    <div className="app-container">
      {/* Top Header / Status Bar */}
      <header className="top-header">
        <div className="brand">
          <span className="brand-logo">🤖</span>
          <h2>QArmDroid</h2>
          <span
            className={`status-pill ${
              status.scrcpy_running || connected || (status.running && displayMode === "sdl")
                ? "connected"
                : status.running
                ? "booting"
                : "stopped"
            }`}
          >
            {status.scrcpy_running
              ? "● Scrcpy Mirror Active"
              : connected
              ? "● Display Live (Embedded)"
              : status.running && displayMode === "sdl"
              ? "● Native SDL Window Active"
              : status.running && status.boot_completed
              ? "● Boot Completed — Attaching Display..."
              : status.running
              ? "● Booting VM (WHPX)..."
              : "○ Stopped"}
          </span>
        </div>

        <div className="header-controls">
          {/* Mode Selector */}
          {!status.running && (
            <div className="mode-toggle">
              <label className={`mode-label ${displayMode === "scrcpy" ? "active" : ""}`}>
                <input
                  type="radio"
                  name="mode"
                  value="scrcpy"
                  checked={displayMode === "scrcpy"}
                  onChange={() => setDisplayMode("scrcpy")}
                />
                📱 Scrcpy Mirror
              </label>
              <label className={`mode-label ${displayMode === "embedded" ? "active" : ""}`}>
                <input
                  type="radio"
                  name="mode"
                  value="embedded"
                  checked={displayMode === "embedded"}
                  onChange={() => setDisplayMode("embedded")}
                />
                🌐 Embedded
              </label>
              <label className={`mode-label ${displayMode === "sdl" ? "active" : ""}`}>
                <input
                  type="radio"
                  name="mode"
                  value="sdl"
                  checked={displayMode === "sdl"}
                  onChange={() => setDisplayMode("sdl")}
                />
                🖥️ Native SDL
              </label>
            </div>
          )}

          {status.adb_ready && (
            <button className="btn btn-secondary" onClick={handleLaunchScrcpy} title="Open Scrcpy mirror window with native touch">
              📱 Open Scrcpy Mirror
            </button>
          )}

          {!status.running ? (
            <button className="btn btn-primary" onClick={handleStart} disabled={!imageConfig.provisioned}>
              ▶ Launch Emulator
            </button>
          ) : (
            <button className="btn btn-danger" onClick={handleStop}>
              ■ Stop Emulator
            </button>
          )}

          <button className="btn btn-secondary" onClick={openSettings} title="Emulator Settings (Runtime, Images, VM Hardware & Preferences)">
            ⚙ Settings
          </button>

          {displayMode === "embedded" && status.vnc_ready && !connected && (
            <button className="btn btn-secondary" onClick={connectVNC}>
              🔄 Reconnect Screen
            </button>
          )}
        </div>
      </header>

      {/* Hardware-accelerated SVG color filter: the embedded VNC framebuffer
          arrives with swapped R/B channels, so always apply the BGR swap. */}
      <svg style={{ position: "absolute", width: 0, height: 0, pointerEvents: "none" }} aria-hidden="true">
        <filter id="bgr-swap" colorInterpolationFilters="sRGB">
          <feColorMatrix
            type="matrix"
            values="0 0 1 0 0
                    0 1 0 0 0
                    1 0 0 0 0
                    0 0 0 1 0"
          />
        </filter>
      </svg>

      {/* Main Workspace: Screen Viewport + Android Control Bar */}
      <main className="main-viewport">
        <div
          className={`screen-wrapper ${displayMode === "embedded" ? "color-mode-bgr" : ""}`}
          onPointerDown={handlePointerDown}
          onPointerMove={handlePointerMove}
          onPointerUp={handlePointerUp}
          onPointerCancel={handlePointerUp}
          onPointerLeave={handlePointerLeave}
          onContextMenu={handleContextMenu}
        >
          {/* RFB Canvas mount point (direct 1:1 hardware touch via low-latency daemon) */}
          <div ref={screenRef} className="vnc-canvas-container" />

          {/* Visual touch feedback ripple */}
          {touchFeedback.visible && (
            <div
              className={`touch-ripple ${isPointerDownRef.current ? "active" : ""}`}
              style={{
                left: `${touchFeedback.x}px`,
                top: `${touchFeedback.y}px`,
              }}
            />
          )}

          {/* Placeholder overlay when not connected, in Scrcpy mode, or in SDL mode */}
          {(!connected || displayMode !== "embedded") && (
            <div className="screen-placeholder">
              {status.running && displayMode === "scrcpy" ? (
                <div className="placeholder-content">
                  <span className="device-icon">📱</span>
                  <h3>Scrcpy Mirror Active</h3>
                  <p>Android is streaming via low-latency hardware mirror with fluid touch.</p>
                  <p className="subtext">Use your mouse or touchscreen inside the Scrcpy window directly.</p>
                  <button className="btn btn-primary btn-large" onClick={handleLaunchScrcpy} style={{ marginTop: "16px" }}>
                    📱 Re-open Scrcpy Window
                  </button>
                </div>
              ) : status.running && displayMode === "sdl" ? (
                <div className="placeholder-content">
                  <span className="device-icon">⚡</span>
                  <h3>Native GPU Window Running</h3>
                  <p>Android is rendering directly in a native SDL DirectX/OpenGL window at full 60 FPS.</p>
                  <p className="subtext">Use the toolbar on the right to send navigation and text input via ADB.</p>
                </div>
              ) : connecting || (status.running && !status.vnc_ready && !status.adb_ready) ? (
                <div className="placeholder-content">
                  <div className="spinner" />
                  <h3>Booting Android System...</h3>
                  <p>Initializing Hypervisor (WHPX) & Guest Services</p>
                  <span className="subtext">Display will attach automatically once ready</span>
                </div>
              ) : (
                <div className="placeholder-content">
                  <span className="device-icon">🤖</span>
                  <h3>Emulator Ready</h3>
                  <p>
                    Selected mode: <strong>{displayMode === "scrcpy" ? "📱 Scrcpy Mirror" : displayMode === "embedded" ? "🌐 In-App Embedded Canvas" : "🖥️ Native SDL Window"}</strong>
                  </p>
                  <button className="btn btn-primary btn-large" onClick={handleStart}>
                    ▶ Launch Android System
                  </button>
                </div>
              )}
            </div>
          )}
        </div>

        {/* Right / Bottom Phone Hardware Controls */}
        <aside className="nav-toolbar">
          <div className="toolbar-section">
            <span className="section-title">Navigation</span>
            <div className="button-group">
              <button
                className="tool-btn"
                title="Back (KEYCODE_BACK, Esc, Right-Click)"
                onClick={() => sendKey("4")}
                disabled={!isKeyControlReady}
              >
                ◀ Back
              </button>
              <button
                className="tool-btn"
                title="Home (KEYCODE_HOME, F3)"
                onClick={() => sendKey("3")}
                disabled={!isKeyControlReady}
              >
                ⌂ Home
              </button>
              <button
                className="tool-btn"
                title="Recents / App Switcher (KEYCODE_APP_SWITCH, F1)"
                onClick={() => sendKey("187")}
                disabled={!isKeyControlReady}
              >
                ▢ Recents
              </button>
            </div>
          </div>

          <div className="toolbar-section">
            <span className="section-title">Hardware Keys</span>
            <div className="button-group">
              <button
                className="tool-btn"
                title="Volume Up"
                onClick={() => sendKey("24")}
                disabled={!isKeyControlReady}
              >
                🔊 Vol +
              </button>
              <button
                className="tool-btn"
                title="Volume Down"
                onClick={() => sendKey("25")}
                disabled={!isKeyControlReady}
              >
                🔉 Vol -
              </button>
              <button
                className="tool-btn"
                title="Power Button"
                onClick={() => sendKey("26")}
                disabled={!isKeyControlReady}
              >
                ⏻ Power
              </button>
            </div>
          </div>

          <div className="toolbar-section">
            <span className="section-title">Type into Device</span>
            <form onSubmit={handleSendText} className="input-form">
              <input
                type="text"
                placeholder="Type text & enter..."
                value={inputText}
                onChange={(e) => setInputText(e.target.value)}
                disabled={!isKeyControlReady}
              />
              <button type="submit" className="btn btn-secondary" disabled={!isKeyControlReady}>
                Send
              </button>
            </form>
          </div>

          <div className="toolbar-section system-info">
            <span className="section-title">Engine Info</span>
            <div className="info-grid">
              <div>CPU / Accel: <strong>WHPX (Host)</strong></div>
              <div>GPU Engine: <strong>VirtIO SwiftShader</strong></div>
              <div>Touch Engine: <strong>1:1 Native Direct Daemon</strong></div>
              <div>ADB Target: <strong>127.0.0.1:5555</strong></div>
              <div>Display: <strong>{displayMode === "embedded" ? "ws://127.0.0.1:5901" : "Native SDL"}</strong></div>
            </div>
          </div>
        </aside>
      </main>

      {/* Footer Log Bar */}
      <footer className="footer-bar">
        <span className="footer-status">{logMsg}</span>
        <div className="footer-badges">
          <span className={`badge ${status.adb_ready ? "badge-ok" : "badge-dim"}`}>
            ADB: {status.adb_ready ? "Connected" : "Offline"}
          </span>
          <span className={`badge ${status.vnc_ready ? "badge-ok" : "badge-dim"}`}>
            VNC: {status.vnc_ready ? "5901" : "Closed"}
          </span>
        </div>
      </footer>

      {showSettings && (
        <SettingsModal
          config={imageConfig}
          draft={settingsDraft}
          setDraft={setSettingsDraft}
          provisioning={provisioning}
          provision={provision}
          isEmulatorRunning={status.running}
          displayMode={displayMode}
          setDisplayMode={setDisplayMode}
          onInstall={() => requestRebuild(false)}
          onForceReinstall={() => requestRebuild(true)}
          onSave={saveSettingsDraft}
          onOpenRuntimeFolder={handleOpenRuntimeFolder}
          onOptimize={handleOptimize}
          onClose={closeSettings}
        />
      )}

      {/* Save Settings Confirmation Pop Up Modal */}
      {savePopup.visible && (
        <div className="popup-overlay" onClick={() => setSavePopup({ visible: false, message: "" })}>
          <div className="popup-dialog" onClick={(e) => e.stopPropagation()}>
            <div className="popup-header">
              <span className="popup-icon">{savePopup.isError ? "❌" : "✅"}</span>
              <h3>{savePopup.isError ? "Error Saving Settings" : "Settings Saved"}</h3>
            </div>
            <div className="popup-body">
              <p className="popup-desc">
                {savePopup.isError
                  ? "An error occurred while saving your configuration:"
                  : "Your configuration changes have been applied and persisted:"}
              </p>
              <pre className="popup-pre">{savePopup.message}</pre>
            </div>
            <div className="popup-footer">
              <button
                className="btn btn-primary"
                onClick={() => setSavePopup({ visible: false, message: "" })}
              >
                OK
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Rebuild & Data Wipe Confirmation Warning Modal */}
      {confirmRebuild.visible && (
        <div className="popup-overlay" onClick={() => setConfirmRebuild((c) => ({ ...c, visible: false }))}>
          <div className="popup-dialog warning" onClick={(e) => e.stopPropagation()}>
            <div className="popup-header">
              <span className="popup-icon">⚠️</span>
              <h3>Confirm Disk Rebuild & Factory Reset</h3>
            </div>
            <div className="popup-body">
              <div className="popup-warn-box">
                <strong>⚠️ Warning: All Android User Data Will Be Reset</strong>
                <p>
                  Virtual partition resizing cannot be performed on encrypted Android userdata without re-initializing the filesystem.
                  Proceeding will <strong>erase all user data, installed applications, and personal settings</strong> (equivalent to a Factory Reset).
                </p>
                <p>
                  <em>Note: The core Android 16 system image is immutable and preserved. Only the user storage partition (/data) is reset.</em>
                </p>
              </div>

              <div className="popup-specs">
                <div className="popup-specs-row">
                  <span>Operation:</span>
                  <strong>
                    {confirmRebuild.force
                      ? "Full Reinstallation"
                      : confirmRebuild.isShrink
                      ? "Shrink Virtual Disk (📉)"
                      : confirmRebuild.isExpand
                      ? "Expand Virtual Disk (📈)"
                      : "Rebuild Partition Layout"}
                  </strong>
                </div>
                <div className="popup-specs-row">
                  <span>Current Capacity:</span>
                  <span>{confirmRebuild.currentSizeGb} GB</span>
                </div>
                <div className="popup-specs-row">
                  <span>New Capacity:</span>
                  <strong>{confirmRebuild.targetSizeGb} GB</strong>
                </div>
                <div className="popup-specs-row">
                  <span>Target Filesystem:</span>
                  <span>{confirmRebuild.fsFormat}</span>
                </div>
              </div>
            </div>
            <div className="popup-footer">
              <button
                className="btn btn-secondary"
                onClick={() => setConfirmRebuild((c) => ({ ...c, visible: false }))}
              >
                Cancel
              </button>
              <button
                className="btn btn-danger"
                onClick={() => {
                  const force = confirmRebuild.force;
                  setConfirmRebuild((c) => ({ ...c, visible: false }));
                  handleProvision(force, true);
                }}
              >
                Yes, Rebuild & Reset Data
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// -----------------------------------------------------------------------------
// Android Settings Modal: Tabbed management for Images & Storage, Runtime &
// Tools, VM & Hardware Options, and System Information.
// -----------------------------------------------------------------------------
interface SettingsModalProps {
  config: ImageConfig;
  draft: {
    sizeGb: number;
    fs: string;
    cores: number;
    memoryGb: number;
    gpuMode: string;
    closeOnExit: boolean;
    tabletMode: boolean;
    gestureNav: boolean;
  };
  setDraft: React.Dispatch<
    React.SetStateAction<{
      sizeGb: number;
      fs: string;
      cores: number;
      memoryGb: number;
      gpuMode: string;
      closeOnExit: boolean;
      tabletMode: boolean;
      gestureNav: boolean;
    }>
  >;
  provisioning: boolean;
  provision: ProvisionProgress;
  isEmulatorRunning: boolean;
  displayMode: "scrcpy" | "embedded" | "sdl";
  setDisplayMode: (m: "scrcpy" | "embedded" | "sdl") => void;
  onInstall: () => void;
  onForceReinstall: () => void;
  onSave: () => void;
  onOpenRuntimeFolder: () => void;
  onOptimize: () => void;
  onClose: () => void;
}

const PRESET_DISK_SIZES = [8, 16, 32, 64];
const CORE_OPTIONS = [4, 6, 8];
const MEMORY_OPTIONS = [4, 6, 8, 12, 16];

function SettingsModal({
  config,
  draft,
  setDraft,
  provisioning,
  provision,
  isEmulatorRunning,
  displayMode,
  setDisplayMode,
  onInstall,
  onForceReinstall,
  onSave,
  onOpenRuntimeFolder,
  onOptimize,
  onClose,
}: SettingsModalProps) {
  const [activeTab, setActiveTab] = useState<"images" | "runtime" | "options" | "about">("images");
  const [isCustomSize, setIsCustomSize] = useState<boolean>(() => !PRESET_DISK_SIZES.includes(draft.sizeGb));
  const [customInputVal, setCustomInputVal] = useState<string>(draft.sizeGb.toString());

  const handleSelectPreset = (gb: number) => {
    setIsCustomSize(false);
    setDraft((d) => ({ ...d, sizeGb: gb }));
    setCustomInputVal(gb.toString());
  };

  const handleSelectCustom = () => {
    setIsCustomSize(true);
    const n = parseInt(customInputVal, 10);
    if (!isNaN(n) && n >= 4 && n <= 256) {
      setDraft((d) => ({ ...d, sizeGb: n }));
    }
  };

  const handleCustomChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const s = e.target.value;
    setCustomInputVal(s);
    const n = parseInt(s, 10);
    if (!isNaN(n) && n >= 4 && n <= 256) {
      setDraft((d) => ({ ...d, sizeGb: n }));
    }
  };

  const handleCustomBlur = () => {
    let n = parseInt(customInputVal, 10);
    if (isNaN(n) || n < 4) n = 4;
    if (n > 256) n = 256;
    setCustomInputVal(n.toString());
    setDraft((d) => ({ ...d, sizeGb: n }));
  };

  const showProgress = provisioning || provision.done || provision.percent > 0;
  const pct = Math.max(0, Math.min(100, provision.percent));

  return (
    <div
      className="config-overlay"
      onClick={(e) => {
        if (e.target === e.currentTarget && !provisioning) onClose();
      }}
    >
      <div className="config-panel settings-panel">
        <div className="config-head">
          <div>
            <h2>⚙️ Emulator Settings</h2>
            <p className="config-sub">
              Manage runtime environments, virtual disks, hardware allocation and launch options.
            </p>
          </div>
          {!provisioning && (
            <button className="config-close" onClick={onClose} title="Close Settings">
              ✕
            </button>
          )}
        </div>

        {/* Navigation Tabs */}
        <div className="settings-tabs">
          <button
            className={`settings-tab-btn ${activeTab === "images" ? "active" : ""}`}
            onClick={() => setActiveTab("images")}
          >
            💾 Images & Storage
          </button>
          <button
            className={`settings-tab-btn ${activeTab === "runtime" ? "active" : ""}`}
            onClick={() => setActiveTab("runtime")}
          >
            🛠️ Runtime & Tools
          </button>
          <button
            className={`settings-tab-btn ${activeTab === "options" ? "active" : ""}`}
            onClick={() => setActiveTab("options")}
          >
            ⚡ VM & Hardware
          </button>
          <button
            className={`settings-tab-btn ${activeTab === "about" ? "active" : ""}`}
            onClick={() => setActiveTab("about")}
          >
            ℹ️ System & About
          </button>
        </div>

        {/* Tab 1: Images & Storage */}
        {activeTab === "images" && (
          <div className="tab-body">
            <div className="config-status-row">
              <span className={`status-chip ${config.kernel_present ? "ok" : "warn"}`}>
                Kernel: {config.kernel_present ? "Present" : "Missing"}
              </span>
              <span className={`status-chip ${config.super_present ? "ok" : "warn"}`}>
                Super Image: {config.super_present ? "Present" : "Missing"}
              </span>
              <span className={`status-chip ${config.disk_present ? "ok" : "warn"}`}>
                Userdata Disk: {config.disk_present ? `Built (${config.disk_size_gb}GB ${config.fs_format})` : "Not Built"}
              </span>
            </div>

            <div className="config-grid">
              {/* Disk size */}
              <section className="config-section">
                <span className="section-title">Userdata Disk Size</span>
                <p className="section-help">
                  Virtual storage capacity allocated for Android applications and user data (4 - 256 GB).
                </p>
                <div className="seg-control">
                  {PRESET_DISK_SIZES.map((gb) => (
                    <button
                      key={gb}
                      className={`seg-btn ${!isCustomSize && draft.sizeGb === gb ? "active" : ""}`}
                      disabled={provisioning}
                      onClick={() => handleSelectPreset(gb)}
                    >
                      {gb} GB
                    </button>
                  ))}
                  <button
                    className={`seg-btn ${isCustomSize ? "active" : ""}`}
                    disabled={provisioning}
                    onClick={handleSelectCustom}
                  >
                    Custom
                    <small>{isCustomSize ? `${draft.sizeGb} GB` : "Custom Size"}</small>
                  </button>
                </div>

                {isCustomSize && (
                  <div className="custom-size-box">
                    <div className="custom-size-row">
                      <label htmlFor="custom-disk-input">Custom Size:</label>
                      <div className="custom-input-group">
                        <input
                          id="custom-disk-input"
                          type="number"
                          min="4"
                          max="256"
                          value={customInputVal}
                          onChange={handleCustomChange}
                          onBlur={handleCustomBlur}
                          disabled={provisioning}
                        />
                        <span className="unit-label">GB</span>
                      </div>
                    </div>
                    <span className="custom-size-hint">Enter custom size from 4 GB to 256 GB</span>
                  </div>
                )}

                {/* Shrink / Expand Notices */}
                {config.disk_present && draft.sizeGb < config.disk_size_gb && (
                  <div className="partition-notice shrink">
                    <span className="notice-icon">📉</span>
                    <div className="notice-content">
                      <strong>Shrink Partition: {config.disk_size_gb} GB → {draft.sizeGb} GB</strong>
                      <p>
                        Decreasing capacity requires rebuilding disk.raw down to {draft.sizeGb} GB.
                        <strong> Note: All Android guest user data will be reset (Factory Reset).</strong>
                      </p>
                    </div>
                  </div>
                )}

                {config.disk_present && draft.sizeGb > config.disk_size_gb && (
                  <div className="partition-notice expand">
                    <span className="notice-icon">📈</span>
                    <div className="notice-content">
                      <strong>Expand Partition: {config.disk_size_gb} GB → {draft.sizeGb} GB</strong>
                      <p>
                        Increasing capacity will rebuild the partition layout to {draft.sizeGb} GB.
                        <strong> Note: Partition resizing requires re-initializing user data (Factory Reset).</strong>
                      </p>
                    </div>
                  </div>
                )}

                {isEmulatorRunning && (
                  <div className="partition-notice shrink">
                    <span className="notice-icon">⚠️</span>
                    <div className="notice-content">
                      <strong>Emulator is currently running</strong>
                      <p>Please click 'Stop Emulator' from the main toolbar before rebuilding or resizing virtual disks.</p>
                    </div>
                  </div>
                )}
              </section>

              {/* Filesystem format */}
              <section className="config-section">
                <span className="section-title">Userdata Filesystem</span>
                <p className="section-help">
                  Filesystem format for <code>/data</code> partition created during provisioning.
                </p>
                <div className="seg-control">
                  <button
                    className={`seg-btn ${draft.fs === "ext4" ? "active" : ""}`}
                    disabled={provisioning || isEmulatorRunning}
                    onClick={() => setDraft((d) => ({ ...d, fs: "ext4" }))}
                  >
                    ext4
                    <small>Standard, highly robust</small>
                  </button>
                  <button
                    className={`seg-btn ${draft.fs === "f2fs" ? "active" : ""}`}
                    disabled={provisioning || isEmulatorRunning}
                    onClick={() => setDraft((d) => ({ ...d, fs: "f2fs" }))}
                  >
                    f2fs
                    <small>Flash-native, faster writes</small>
                  </button>
                </div>
              </section>
            </div>

            {/* Progress */}
            {showProgress && (
              <div className="config-progress">
                <div className="progress-track">
                  <div
                    className={`progress-fill ${provision.error ? "error" : provision.done ? "done" : ""}`}
                    style={{ width: `${pct}%` }}
                  />
                </div>
                <div className="progress-meta">
                  <span className={`progress-stage ${provision.error ? "err" : ""}`}>
                    {provision.error ? "❌ " : provision.done ? "✅ " : ""}
                    {provision.stage || "Working…"}
                  </span>
                  <span className="progress-pct">{pct}%</span>
                </div>
                {provision.message && (
                  <div className="progress-log">{provision.message}</div>
                )}
              </div>
            )}

            <div className="config-actions">
              <button
                className="btn btn-primary btn-large"
                disabled={provisioning || isEmulatorRunning}
                onClick={onInstall}
                title={isEmulatorRunning ? "Stop emulator first before rebuilding disk" : undefined}
              >
                {config.provisioned ? "⤓ Rebuild / Update Disk" : "▼ Install Android Image"}
              </button>
              {config.provisioned && (
                <button
                  className="btn btn-secondary"
                  disabled={provisioning || isEmulatorRunning}
                  onClick={onForceReinstall}
                  title={isEmulatorRunning ? "Stop emulator first before reinstalling" : "Re-copy image assets and build clean disk.raw"}
                >
                  ⟳ Force Reinstall
                </button>
              )}
              {!provisioning && (
                <button
                  className="btn btn-secondary"
                  disabled={isEmulatorRunning}
                  onClick={onSave}
                  title="Save storage settings"
                >
                  💾 Save Preferences
                </button>
              )}
            </div>

            {!config.provisioned && !provisioning && (
              <p className="config-note">
                💡 First time? Click <strong>Install Android Image</strong>. This sets up the runtime directory,
                provisions the QEMU engine, and builds the Android 16 raw GPT disk image.
              </p>
            )}
          </div>
        )}

        {/* Tab 2: Runtime & Tools */}
        {activeTab === "runtime" && (
          <div className="tab-body">
            <div className="runtime-banner">
              <div className="runtime-banner-info">
                <span className="runtime-banner-title">📁 Provisioned Runtime Root</span>
                <span className="runtime-banner-path" title={config.runtime_root}>
                  {config.runtime_root || "Not yet provisioned (%LOCALAPPDATA%\\QArmDroid)"}
                </span>
              </div>
              <button
                className="btn btn-secondary btn-sm"
                onClick={onOpenRuntimeFolder}
                title="Open runtime folder in Windows File Explorer"
              >
                📂 Open in Explorer
              </button>
            </div>

            <div className="component-list">
              <div className="component-card">
                <div className="component-header">
                  <div className="component-title">
                    <span className="component-icon">⚡</span>
                    <strong>QEMU Hypervisor (ARM64 WHPX)</strong>
                  </div>
                  <span className={`status-badge ${config.qemu_present ? "ok" : "err"}`}>
                    {config.qemu_present ? "Detected" : "Missing"}
                  </span>
                </div>
                <p className="component-desc">
                  ARM64 native binary compiled with WHPX hardware acceleration and virtio-gpu support.
                </p>
                <div className="component-path">
                  <code>{config.qemu_path || "Auto-detected during launch"}</code>
                </div>
              </div>

              <div className="component-card">
                <div className="component-header">
                  <div className="component-title">
                    <span className="component-icon">📱</span>
                    <strong>Scrcpy Display Mirror</strong>
                  </div>
                  <span className={`status-badge ${config.scrcpy_present ? "ok" : "err"}`}>
                    {config.scrcpy_present ? "Bundled" : "Missing"}
                  </span>
                </div>
                <p className="component-desc">
                  Direct3D 11 hardware-rendered mirror providing low-latency video streaming and touch control.
                </p>
                <div className="component-path">
                  <code>{config.scrcpy_path || "tools/scrcpy/scrcpy.exe"}</code>
                </div>
              </div>

              <div className="component-card">
                <div className="component-header">
                  <div className="component-title">
                    <span className="component-icon">🔌</span>
                    <strong>Android Debug Bridge (ADB)</strong>
                  </div>
                  <span className={`status-badge ${config.adb_present ? "ok" : "warn"}`}>
                    {config.adb_present ? "Connected" : "Not on PATH"}
                  </span>
                </div>
                <p className="component-desc">
                  Used for guest command dispatch, key injection, daemon port forwarding, and system status checks.
                </p>
                <div className="component-path">
                  <code>{config.adb_path || "adb"}</code>
                </div>
              </div>

              <div className="component-card">
                <div className="component-header">
                  <div className="component-title">
                    <span className="component-icon">🐍</span>
                    <strong>Python Environment</strong>
                  </div>
                  <span className={`status-badge ${config.python_present ? "ok" : "warn"}`}>
                    {config.python_present ? "Ready" : "Missing"}
                  </span>
                </div>
                <p className="component-desc">
                  Bundled Python executable used for raw disk partition generation and provisioning utilities.
                </p>
              </div>
            </div>

            <div className="config-actions">
              <button className="btn btn-secondary" onClick={onOpenRuntimeFolder}>
                📂 Open Runtime Directory
              </button>
            </div>
          </div>
        )}

        {/* Tab 3: VM & Hardware Options */}
        {activeTab === "options" && (
          <div className="tab-body">
            <div className="config-grid">
              {/* Display Mode */}
              <section className="config-section">
                <span className="section-title">Default Display Mode</span>
                <p className="section-help">
                  Select which video output engine to attach upon emulator launch.
                </p>
                <div className="seg-control">
                  <button
                    className={`seg-btn ${displayMode === "embedded" ? "active" : ""}`}
                    onClick={() => setDisplayMode("embedded")}
                  >
                    🌐 Embedded
                    <small>Canvas inside window</small>
                  </button>
                  <button
                    className={`seg-btn ${displayMode === "scrcpy" ? "active" : ""}`}
                    onClick={() => setDisplayMode("scrcpy")}
                  >
                    📱 Scrcpy
                    <small>Hardware-rendered mirror</small>
                  </button>
                  <button
                    className={`seg-btn ${displayMode === "sdl" ? "active" : ""}`}
                    onClick={() => setDisplayMode("sdl")}
                  >
                    🖥️ SDL
                    <small>Native DirectX window</small>
                  </button>
                </div>
              </section>

              {/* System Navigation Mode */}
              <section className="config-section">
                <span className="section-title">System Navigation</span>
                <p className="section-help">
                  Choose navigation mode. Gesture navigation removes bottom bar padding for a clean edge-to-edge view.
                </p>
                <div className="seg-control">
                  <button
                    className={`seg-btn ${draft.gestureNav ? "active" : ""}`}
                    onClick={() => setDraft((d) => ({ ...d, gestureNav: true }))}
                  >
                    👉 Switch to Gesture Navigation
                    <small>Edge-to-edge display (Default)</small>
                  </button>
                  <button
                    className={`seg-btn ${!draft.gestureNav ? "active" : ""}`}
                    onClick={() => setDraft((d) => ({ ...d, gestureNav: false }))}
                  >
                    ⏹️ 3-Button Navigation
                    <small>Classic Back, Home, Recents</small>
                  </button>
                </div>
              </section>

              {/* UI Form Factor & Tablet Mode */}
              <section className="config-section">
                <span className="section-title">UI Form Factor (Tablet Mode)</span>
                <p className="section-help">
                  Tablet mode sets display density to 213 dpi (600+ dp width), enabling dual-pane layouts, app dock, and tablet multitasking.
                </p>
                <div className="seg-control">
                  <button
                    className={`seg-btn ${!draft.tabletMode ? "active" : ""}`}
                    onClick={() => setDraft((d) => ({ ...d, tabletMode: false }))}
                  >
                    📱 Standard Phone Mode
                    <small>240 dpi, standard landscape</small>
                  </button>
                  <button
                    className={`seg-btn ${draft.tabletMode ? "active" : ""}`}
                    onClick={() => setDraft((d) => ({ ...d, tabletMode: true }))}
                  >
                    📟 Tablet Mode (600+ dp)
                    <small>213 dpi, dual-pane UI & dock</small>
                  </button>
                </div>
              </section>

              {/* vCPU Cores */}
              <section className="config-section">
                <span className="section-title">vCPU Core Count</span>
                <p className="section-help">
                  Number of host CPU cores passed to QEMU (-smp).
                </p>
                <div className="seg-control">
                  {CORE_OPTIONS.map((c) => (
                    <button
                      key={c}
                      className={`seg-btn ${draft.cores === c ? "active" : ""}`}
                      onClick={() => setDraft((d) => ({ ...d, cores: c }))}
                    >
                      {c} Cores
                      <small>{c === 6 ? "Recommended (Snapdragon)" : c === 4 ? "Power-saver" : "High load"}</small>
                    </button>
                  ))}
                </div>
              </section>

              {/* RAM Memory */}
              <section className="config-section">
                <span className="section-title">RAM Allocation</span>
                <p className="section-help">
                  Host system memory dedicated to the Android guest (-m).
                </p>
                <div className="seg-control">
                  {MEMORY_OPTIONS.map((m) => (
                    <button
                      key={m}
                      className={`seg-btn ${draft.memoryGb === m ? "active" : ""}`}
                      onClick={() => setDraft((d) => ({ ...d, memoryGb: m }))}
                    >
                      {m} GB
                      <small>{m === 6 ? "Default" : m >= 12 ? "Pro apps" : "Standard"}</small>
                    </button>
                  ))}
                </div>
              </section>

              {/* GPU Mode */}
              <section className="config-section">
                <span className="section-title">GPU Acceleration Mode</span>
                <p className="section-help">
                  Graphics rendering pipeline and driver emulation mode.
                </p>
                <div className="seg-control">
                  <button
                    className={`seg-btn ${draft.gpuMode === "basic" ? "active" : ""}`}
                    onClick={() => setDraft((d) => ({ ...d, gpuMode: "basic" }))}
                  >
                    basic
                    <small>VirtIO SwiftShader (100% stable)</small>
                  </button>
                  <button
                    className={`seg-btn ${draft.gpuMode === "gfxstream" ? "active" : ""}`}
                    onClick={() => setDraft((d) => ({ ...d, gpuMode: "gfxstream" }))}
                  >
                    gfxstream
                    <small>Rutabaga Vulkan passthrough</small>
                  </button>
                </div>
              </section>

              {/* Application Exit Behavior */}
              <section className="config-section">
                <span className="section-title">Application Exit Behavior</span>
                <p className="section-help">
                  Choose whether closing this window terminates the running Android emulator.
                </p>
                <div className="seg-control">
                  <button
                    className={`seg-btn ${draft.closeOnExit ? "active" : ""}`}
                    onClick={() => setDraft((d) => ({ ...d, closeOnExit: true }))}
                  >
                    🛑 Close Emulator
                    <small>Terminate QEMU when window exits</small>
                  </button>
                  <button
                    className={`seg-btn ${!draft.closeOnExit ? "active" : ""}`}
                    onClick={() => setDraft((d) => ({ ...d, closeOnExit: false }))}
                  >
                    🔄 Keep Running
                    <small>Leave emulator active in background</small>
                  </button>
                </div>
              </section>
            </div>

            <div className="optimization-card">
              <div>
                <strong>⚡ Android Guest Animation Speedup</strong>
                <p className="section-help">
                  Eliminates window, transition, and animator duration scales in the Android guest for instantaneous app switching.
                </p>
              </div>
              <button className="btn btn-secondary" onClick={onOptimize}>
                ⚡ Optimize Now
              </button>
            </div>

            <div className="config-actions">
              <button className="btn btn-primary" onClick={onSave} title="Save hardware and display preferences">
                💾 Save Preferences
              </button>
            </div>
          </div>
        )}

        {/* Tab 4: System & About */}
        {activeTab === "about" && (
          <div className="tab-body">
            <div className="about-grid">
              <div className="about-item">
                <span className="about-label">Host Operating System</span>
                <span className="about-val">Windows 11 ARM64 (Snapdragon X Elite / Oryon)</span>
              </div>
              <div className="about-item">
                <span className="about-label">Hypervisor Platform</span>
                <span className="about-val">Windows Hypervisor Platform (WHPX / -accel whpx)</span>
              </div>
              <div className="about-item">
                <span className="about-label">Guest Android Target</span>
                <span className="about-val">Android 16 (Baklava) AOSP ARM64 Phone (Cuttlefish)</span>
              </div>
              <div className="about-item">
                <span className="about-label">Input Architecture</span>
                <span className="about-val">Zero-Latency Native TCP Daemon (6666) + Direct USB HID</span>
              </div>
              <div className="about-item">
                <span className="about-label">Networking & Ports</span>
                <span className="about-val">VNC: 127.0.0.1:5901 | ADB: 127.0.0.1:5555 | Daemon: 6666</span>
              </div>
              <div className="about-item">
                <span className="about-label">Color Space Handling</span>
                <span className="about-val">Hardware SVG BGR-swap filter (Embedded) / sRGB (Scrcpy / SDL)</span>
              </div>
            </div>

            <p className="config-note">
              QArmDroid — Native ARM64 Android virtualization on Windows on Snapdragon.
            </p>
          </div>
        )}
      </div>
    </div>
  );
}

export default App;
