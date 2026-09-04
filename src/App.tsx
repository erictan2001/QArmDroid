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

  // --- Image setup / provisioning state ---
  const [imageConfig, setImageConfig] = useState<ImageConfig>({
    installed: false,
    provisioned: false,
    disk_size_gb: 16,
    fs_format: "ext4",
    runtime_root: "",
  });
  const [showConfig, setShowConfig] = useState<boolean>(false);
  const [provision, setProvision] = useState<ProvisionProgress>({
    percent: 0,
    stage: "",
    message: "",
    done: false,
    error: false,
  });
  const [provisioning, setProvisioning] = useState<boolean>(false);
  const [configDraft, setConfigDraft] = useState<{ sizeGb: number; fs: string }>({
    sizeGb: 16,
    fs: "ext4",
  });

  const loadImageConfig = async () => {
    try {
      const cfg = await invoke<ImageConfig>("get_image_config");
      setImageConfig(cfg);
      setConfigDraft({ sizeGb: cfg.disk_size_gb || 16, fs: cfg.fs_format || "ext4" });
      // First run and not yet provisioned -> open the setup gate automatically.
      if (!cfg.provisioned && !showConfig) {
        setShowConfig(true);
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
      setLogMsg("Launching Scrcpy mirror window (60 FPS & 100% accurate color)...");
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

        // Native listeners on the RFB canvas: noVNC calls setPointerCapture on
        // the canvas on mousedown (rfb.js), which retargets all pointermove
        // events to the canvas - the wrapper's React handlers never see them
        // during a drag, so the blue circle would stick at the click point.
        // Attaching natively to the canvas itself lets the ripple ALWAYS
        // follow the cursor (hover + drag), independent of capture.
        const canvas = screenRef.current?.querySelector("canvas");
        if (canvas && !(canvas as any).__qarm_ripple_bound) {
          (canvas as any).__qarm_ripple_bound = true;
          const onMove = (pe: PointerEvent) => {
            const coords = getGuestCoords(pe.clientX, pe.clientY);
            if (coords) {
              // Always update position, but only show during active press
              setTouchFeedback({
                x: coords.screenX,
                y: coords.screenY,
                visible: isPointerDownRef.current
              });
            }
          };
          const onDown = (pe: PointerEvent) => {
            const coords = getGuestCoords(pe.clientX, pe.clientY);
            if (coords) {
              isPointerDownRef.current = true;
              setTouchFeedback({ x: coords.screenX, y: coords.screenY, visible: true });
            }
          };
          const onUp = () => {
            isPointerDownRef.current = false;
            setTouchFeedback((prev) => ({ ...prev, visible: false }));
          };
          const onLeave = () => {
            // Don't hide on leave/cancel - pointer might briefly leave during drag
            // Only hide on explicit pointerup
          };
          canvas.addEventListener("pointermove", onMove);
          canvas.addEventListener("pointerover", onMove);
          canvas.addEventListener("pointerdown", onDown);
          canvas.addEventListener("pointerup", onUp);
          // Don't hide on leave/cancel - pointer might briefly leave during drag
          // canvas.addEventListener("pointerleave", onLeave);
          // canvas.addEventListener("pointercancel", onLeave);
          // Store cleanup function for disconnect
          (canvas as any).__qarm_ripple_cleanup = () => {
            canvas.removeEventListener("pointermove", onMove);
            canvas.removeEventListener("pointerover", onMove);
            canvas.removeEventListener("pointerdown", onDown);
            canvas.removeEventListener("pointerup", onUp);
            canvas.removeEventListener("pointerleave", onLeave);
            canvas.removeEventListener("pointercancel", onLeave);
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

  const handlePointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    // Embedded mode: noVNC (viewOnly=false) relays pointer events over VNC
    // to the guest's USB tablet. Do NOT dispatch via the touch daemon (would
    // double-input), but mirror the SDL/scrcpy feedback pattern: show the
    // blue ripple where the press lands and track the drag so the circle
    // never sticks at a previous click position.
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
    // Embedded: while pressed, follow the pointer with the blue circle (same
    // as SDL/scrcpy). On hover noVNC draws its own dot cursor, so nothing to
    // track here - this keeps the two indicators in sync.
    if (displayMode === "embedded") {
      if (isPointerDownRef.current) {
        const coords = getGuestCoords(e.clientX, e.clientY);
        if (coords) {
          setTouchFeedback({ x: coords.screenX, y: coords.screenY, visible: true });
        }
      }
      return;
    }
    if (!isPointerDownRef.current) return;
    const coords = getGuestCoords(e.clientX, e.clientY);
    if (!coords) return;

    setTouchFeedback({ x: coords.screenX, y: coords.screenY, visible: true });
    invoke("send_motion_move", { x: coords.x, y: coords.y }).catch(() => {});
  };

  const handlePointerUp = (e: React.PointerEvent<HTMLDivElement>) => {
    // Embedded: release hides the ripple, exactly like the daemon path.
    if (displayMode === "embedded") {
      isPointerDownRef.current = false;
      setTouchFeedback((prev) => ({ ...prev, visible: false }));
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

  const handleContextMenu = (e: React.MouseEvent) => {
    e.preventDefault();
    // Right-click triggers Android Back button
    sendKey("4");
  };

  const handleStart = async () => {
    if (!imageConfig.provisioned) {
      setLogMsg("Install the Android image first (Configure Image → Install).");
      setShowConfig(true);
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

  // --- Image setup handlers ---
  const openConfig = async () => {
    await loadImageConfig();
    setShowConfig(true);
  };

  const saveConfigDraft = async () => {
    try {
      const cfg = await invoke<ImageConfig>("save_image_config", {
        diskSizeGb: configDraft.sizeGb,
        fsFormat: configDraft.fs,
      });
      setImageConfig(cfg);
    } catch (e) {
      setLogMsg(`Could not save image config: ${e}`);
    }
  };

  const handleProvision = async (force: boolean) => {
    // Persist the chosen size/format before building.
    await saveConfigDraft();
    setProvisioning(true);
    setProvision({
      percent: 0,
      stage: "Starting",
      message: "Preparing to install the Android image...",
      done: false,
      error: false,
    });
    try {
      const msg = await invoke<string>("provision_image", {
        force,
        diskSizeGb: configDraft.sizeGb,
        fsFormat: configDraft.fs,
      });
      setLogMsg(msg);
    } catch (e) {
      setLogMsg(`Provisioning error: ${e}`);
      setProvisioning(false);
    }
  };

  const closeConfig = () => {
    if (provisioning) return; // don't allow closing mid-build
    setShowConfig(false);
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
      {/* Android Image Setup overlay (install / update disk size / format) */}
      {showConfig && (
        <ImageConfigPanel
          config={imageConfig}
          draft={configDraft}
          setDraft={setConfigDraft}
          provisioning={provisioning}
          provision={provision}
          onInstall={() => handleProvision(false)}
          onForceReinstall={() => handleProvision(true)}
          onSave={saveConfigDraft}
          onClose={closeConfig}
        />
      )}

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
              ? "● Scrcpy Mirror Active (60 FPS)"
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
                📱 Scrcpy Mirror (60 FPS)
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
            <button className="btn btn-secondary" onClick={handleLaunchScrcpy} title="Open ultra-fast Scrcpy mirror window with 100% true colors & native touch">
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

          {!status.running && (
            <button className="btn btn-secondary" onClick={openConfig} title="Install or reconfigure the Android image (disk size, filesystem)">
              ⚙ Configure Image
            </button>
          )}

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
          onContextMenu={handleContextMenu}
        >
          {/* RFB Canvas mount point (direct 1:1 hardware touch via low-latency daemon) */}
          <div ref={screenRef} className="vnc-canvas-container" />

          {/* Visual touch feedback ripple */}
          {touchFeedback.visible && (
            <div
              className="touch-ripple"
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
                  <p>Android is streaming in ultra-smooth 60 FPS with 100% accurate native sRGB colors & fluid touch.</p>
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
                    Selected mode: <strong>{displayMode === "scrcpy" ? "📱 Scrcpy Mirror (Ultra-Fluid 60FPS & True Colors)" : displayMode === "embedded" ? "🌐 In-App Embedded Canvas" : "🖥️ Native SDL Window"}</strong>
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
    </div>
  );
}

// -----------------------------------------------------------------------------
// Android Image Setup panel: install / update the runtime, choose disk size and
// userdata filesystem. Long operations stream real progress from the Rust host.
// -----------------------------------------------------------------------------
interface ImageConfigPanelProps {
  config: ImageConfig;
  draft: { sizeGb: number; fs: string };
  setDraft: React.Dispatch<React.SetStateAction<{ sizeGb: number; fs: string }>>;
  provisioning: boolean;
  provision: ProvisionProgress;
  onInstall: () => void;
  onForceReinstall: () => void;
  onSave: () => void;
  onClose: () => void;
}

const DISK_SIZES = [16, 32, 64, 128];

function ImageConfigPanel({
  config,
  draft,
  setDraft,
  provisioning,
  provision,
  onInstall,
  onForceReinstall,
  onSave,
  onClose,
}: ImageConfigPanelProps) {
  const showProgress = provisioning || provision.done || provision.percent > 0;
  const pct = Math.max(0, Math.min(100, provision.percent));

  return (
    <div className="config-overlay">
      <div className="config-panel">
        <div className="config-head">
          <div>
            <h2>🤖 Android Image Setup</h2>
            <p className="config-sub">
              Install the ARM64 Android image and configure its virtual disk before launching the emulator.
            </p>
          </div>
          {!provisioning && (
            <button className="config-close" onClick={onClose} title="Close">
              ✕
            </button>
          )}
        </div>

        <div className="config-status-row">
          <span className={`status-chip ${config.installed ? "ok" : "warn"}`}>
            Runtime: {config.installed ? "Present" : "Missing"}
          </span>
          <span className={`status-chip ${config.provisioned ? "ok" : "warn"}`}>
            Image: {config.provisioned ? "Installed" : "Not installed"}
          </span>
          {config.runtime_root && (
            <span className="status-chip muted" title={config.runtime_root}>
              {config.runtime_root.length > 42
                ? "…" + config.runtime_root.slice(-40)
                : config.runtime_root}
            </span>
          )}
        </div>

        <div className="config-grid">
          {/* Disk size */}
          <section className="config-section">
            <span className="section-title">Userdata Disk Size</span>
            <p className="section-help">
              Space allocated for Android apps &amp; data (virtual GPT partition).
            </p>
            <div className="seg-control">
              {DISK_SIZES.map((gb) => (
                <button
                  key={gb}
                  className={`seg-btn ${draft.sizeGb === gb ? "active" : ""}`}
                  disabled={provisioning}
                  onClick={() => setDraft((d) => ({ ...d, sizeGb: gb }))}
                >
                  {gb} GB
                </button>
              ))}
            </div>
          </section>

          {/* Filesystem format */}
          <section className="config-section">
            <span className="section-title">Userdata Filesystem</span>
            <p className="section-help">
              Format used for the <code>/data</code> partition on first boot.
            </p>
            <div className="seg-control">
              <button
                className={`seg-btn ${draft.fs === "ext4" ? "active" : ""}`}
                disabled={provisioning}
                onClick={() => setDraft((d) => ({ ...d, fs: "ext4" }))}
              >
                ext4
                <small>Stable, widely compatible</small>
              </button>
              <button
                className={`seg-btn ${draft.fs === "f2fs" ? "active" : ""}`}
                disabled={provisioning}
                onClick={() => setDraft((d) => ({ ...d, fs: "f2fs" }))}
              >
                f2fs
                <small>Flash-optimized, faster on SSD</small>
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

        {/* Actions */}
        <div className="config-actions">
          <button
            className="btn btn-primary btn-large"
            disabled={provisioning}
            onClick={onInstall}
          >
            {config.provisioned ? "⤓ Update / Rebuild Image" : "▼ Install Android Image"}
          </button>
          {config.provisioned && (
            <button
              className="btn btn-secondary"
              disabled={provisioning}
              onClick={onForceReinstall}
              title="Force re-copy QEMU/image and rebuild disk.raw"
            >
              ⟳ Force Reinstall
            </button>
          )}
          {!provisioning && (
            <button className="btn btn-secondary" onClick={onSave} title="Save size/format selection">
              💾 Save Settings
            </button>
          )}
        </div>

        {!config.provisioned && !provisioning && (
          <p className="config-note">
            First time? Click <strong>Install Android Image</strong>. This copies the emulator engine
            and builds the virtual disk (can take several minutes) — progress is shown above.
          </p>
        )}
      </div>
    </div>
  );
}

export default App;
