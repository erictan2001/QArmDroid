import { useEffect, useRef, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import RFB from "@novnc/novnc";
import "./App.css";

interface EmulatorStatus {
  running: boolean;
  vnc_ready: boolean;
  adb_ready: boolean;
  boot_completed: boolean;
  scrcpy_running: boolean;
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
  const [colorMode, setColorMode] = useState<"direct" | "bgr" | "brg" | "gbr" | "fix_rby">("gbr");
  const [inputText, setInputText] = useState("");
  const [touchFeedback, setTouchFeedback] = useState<{ x: number; y: number; visible: boolean }>({
    x: 0,
    y: 0,
    visible: false,
  });

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
    const timer = setInterval(() => {
      checkStatus();
    }, 1500);
    checkStatus();
    return () => clearInterval(timer);
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

      rfb.addEventListener("connect", () => {
        setConnecting(false);
        setConnected(true);
        setLogMsg("Connected to Android display — VNC input active");
      });

      rfb.addEventListener("disconnect", (e: any) => {
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

  // Auto-correct color mode per display backend. The VNC/embedded framebuffer
  // arrives with GBR channel order (verified empirically); SDL shows native
  // colors after the QEMU sdl2-2d.c colour-fix, so it needs no filter.
  useEffect(() => {
    if (displayMode === "embedded") {
      setColorMode("gbr");
    } else if (displayMode === "sdl") {
      setColorMode("direct");
    }
  }, [displayMode]);

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
    // to the guest's USB tablet. Do NOT also dispatch via the touch daemon
    // (would double-input). The daemon handlers are only for SDL/scrcpy.
    if (displayMode === "embedded" && connected) return;
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
    if (displayMode === "embedded" && connected) return;
    if (!isPointerDownRef.current) return;
    const coords = getGuestCoords(e.clientX, e.clientY);
    if (!coords) return;

    setTouchFeedback({ x: coords.screenX, y: coords.screenY, visible: true });
    invoke("send_motion_move", { x: coords.x, y: coords.y }).catch(() => {});
  };

  const handlePointerUp = (e: React.PointerEvent<HTMLDivElement>) => {
    if (displayMode === "embedded" && connected) return;
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
    // Embedded mode: noVNC forwards mouse buttons over VNC to the guest,
    // so right-click reaches Android natively; no extra Back key needed.
    if (displayMode === "embedded" && connected) return;
    // Right-click triggers Android Back button
    sendKey("4");
  };

  const handleStart = async () => {
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

  const sendKey = async (key: string) => {
    try {
      await invoke("send_adb_key", { key });
    } catch (e) {
      setLogMsg(`ADB key error: ${e}`);
    }
  };

  const handleSendText = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!inputText.trim()) return;
    try {
      const escaped = inputText.replace(/ /g, "%s");
      await invoke("send_adb_text", { text: escaped });
      setInputText("");
    } catch (e) {
      setLogMsg(`ADB text error: ${e}`);
    }
  };

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
            <button className="btn btn-primary" onClick={handleStart}>
              ▶ Launch Emulator
            </button>
          ) : (
            <button className="btn btn-danger" onClick={handleStop}>
              ■ Stop Emulator
            </button>
          )}

          {displayMode === "embedded" && status.vnc_ready && !connected && (
            <button className="btn btn-secondary" onClick={connectVNC}>
              🔄 Reconnect Screen
            </button>
          )}

          {displayMode === "embedded" && (
            <div className="color-control-group">
              <span className="color-label">Color:</span>
              <button
                className={`btn btn-sm ${colorMode === "direct" ? "btn-active" : "btn-secondary"}`}
                onClick={() => setColorMode("direct")}
                title="Direct native sRGB (no filter)"
              >
                Native
              </button>
              <button
                className={`btn btn-sm ${colorMode === "bgr" ? "btn-active" : "btn-secondary"}`}
                onClick={() => setColorMode("bgr")}
                title="Swap Red and Blue (BGR)"
              >
                BGR
              </button>
              <button
                className={`btn btn-sm ${colorMode === "brg" ? "btn-active" : "btn-secondary"}`}
                onClick={() => setColorMode("brg")}
                title="BRG Channel Permutation"
              >
                BRG
              </button>
              <button
                className={`btn btn-sm ${colorMode === "gbr" ? "btn-active" : "btn-secondary"}`}
                onClick={() => setColorMode("gbr")}
                title="GBR Channel Permutation"
              >
                GBR
              </button>
              <button
                className={`btn btn-sm ${colorMode === "fix_rby" ? "btn-active" : "btn-secondary"}`}
                onClick={() => setColorMode("fix_rby")}
                title="Color Sequence Inversion (Red->Blue, Blue->Yellow, Yellow->Red)"
              >
                R-B-Y Fix
              </button>
            </div>
          )}
        </div>
      </header>

      {/* Hardware-accelerated SVG color filters for instant GPU channel correction */}
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
        <filter id="brg-swap" colorInterpolationFilters="sRGB">
          <feColorMatrix
            type="matrix"
            values="0 0 1 0 0
                    1 0 0 0 0
                    0 1 0 0 0
                    0 0 0 1 0"
          />
        </filter>
        <filter id="gbr-swap" colorInterpolationFilters="sRGB">
          <feColorMatrix
            type="matrix"
            values="0 1 0 0 0
                    0 0 1 0 0
                    1 0 0 0 0
                    0 0 0 1 0"
          />
        </filter>
        <filter id="fix-rby-swap" colorInterpolationFilters="sRGB">
          <feColorMatrix
            type="matrix"
            values="0  0 1 0 0
                    1 -1 0 0 0
                    0  1 0 0 0
                    0  0 0 1 0"
          />
        </filter>
      </svg>

      {/* Main Workspace: Screen Viewport + Android Control Bar */}
      <main className="main-viewport">
        <div
          className={`screen-wrapper color-mode-${colorMode}`}
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
                title="Back (KEYCODE_BACK)"
                onClick={() => sendKey("4")}
                disabled={!status.adb_ready}
              >
                ◀ Back
              </button>
              <button
                className="tool-btn"
                title="Home (KEYCODE_HOME)"
                onClick={() => sendKey("3")}
                disabled={!status.adb_ready}
              >
                ⌂ Home
              </button>
              <button
                className="tool-btn"
                title="Recents / App Switcher (KEYCODE_APP_SWITCH)"
                onClick={() => sendKey("187")}
                disabled={!status.adb_ready}
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
                disabled={!status.adb_ready}
              >
                🔊 Vol +
              </button>
              <button
                className="tool-btn"
                title="Volume Down"
                onClick={() => sendKey("25")}
                disabled={!status.adb_ready}
              >
                🔉 Vol -
              </button>
              <button
                className="tool-btn"
                title="Power Button"
                onClick={() => sendKey("26")}
                disabled={!status.adb_ready}
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
                disabled={!status.adb_ready}
              />
              <button type="submit" className="btn btn-secondary" disabled={!status.adb_ready}>
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

export default App;
