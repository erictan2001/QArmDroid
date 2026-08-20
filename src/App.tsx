import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import RFB from "@novnc/novnc";
import "./App.css";

interface EmulatorStatus {
  running: boolean;
  vnc_ready: boolean;
  adb_ready: boolean;
}

export function App() {
  const screenRef = useRef<HTMLDivElement | null>(null);
  const rfbRef = useRef<RFB | null>(null);

  const [status, setStatus] = useState<EmulatorStatus>({
    running: false,
    vnc_ready: false,
    adb_ready: false,
  });
  const [displayMode, setDisplayMode] = useState<"embedded" | "sdl">("embedded");
  const [connecting, setConnecting] = useState(false);
  const [connected, setConnected] = useState(false);
  const [inputText, setInputText] = useState("");
  const [logMsg, setLogMsg] = useState("Ready to launch");

  // Check emulator status periodically
  const checkStatus = async () => {
    try {
      const res = await invoke<EmulatorStatus>("get_emulator_status");
      setStatus(res);
      return res;
    } catch {
      return { running: false, vnc_ready: false, adb_ready: false };
    }
  };

  useEffect(() => {
    const timer = setInterval(() => {
      checkStatus();
    }, 2000);
    checkStatus();
    return () => clearInterval(timer);
  }, []);

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
      rfb.focusOnClick = false;
      rfb.viewOnly = true;        // Direct input is handled natively via ADB for 100% precision
      rfb.background = "#0f172a";

      rfb.addEventListener("connect", () => {
        setConnecting(false);
        setConnected(true);
        setLogMsg("Connected to Android display (Direct Touch Control Active)");
      });

      rfb.addEventListener("disconnect", (e: any) => {
        setConnecting(false);
        setConnected(false);
        rfbRef.current = null;
        setLogMsg(e?.detail?.clean ? "Display stream closed" : "Display disconnected");
      });

      rfbRef.current = rfb;
    } catch (err) {
      setConnecting(false);
      setConnected(false);
      setLogMsg(`Connection failed: ${err}`);
    }
  };

  const [optimized, setOptimized] = useState(false);
  const pointerState = useRef<{
    startX: number;
    startY: number;
    currentX: number;
    currentY: number;
    startTime: number;
    isDown: boolean;
  } | null>(null);

  // Capture-phase pointer listener attached directly to canvas mount point
  useEffect(() => {
    const container = screenRef.current;
    if (!container) return;

    const getCanvasCoords = (clientX: number, clientY: number) => {
      const canvas = container.querySelector("canvas") || container;
      const rect = canvas.getBoundingClientRect();
      if (rect.width === 0 || rect.height === 0) return null;

      const rawX = clientX - rect.left;
      const rawY = clientY - rect.top;

      const androidX = Math.round((rawX / rect.width) * 1280);
      const androidY = Math.round((rawY / rect.height) * 800);

      return {
        x: Math.max(0, Math.min(1280, androidX)),
        y: Math.max(0, Math.min(800, androidY)),
      };
    };

    const handlePointerDownNative = (e: PointerEvent) => {
      if (displayMode !== "embedded" || !connected) return;
      const coords = getCanvasCoords(e.clientX, e.clientY);
      if (!coords) return;

      pointerState.current = {
        startX: coords.x,
        startY: coords.y,
        currentX: coords.x,
        currentY: coords.y,
        startTime: Date.now(),
        isDown: true,
      };

      try {
        (e.target as HTMLElement)?.setPointerCapture?.(e.pointerId);
      } catch {}
    };

    const handlePointerMoveNative = (e: PointerEvent) => {
      if (!pointerState.current || !pointerState.current.isDown) return;
      const coords = getCanvasCoords(e.clientX, e.clientY);
      if (!coords) return;

      pointerState.current.currentX = coords.x;
      pointerState.current.currentY = coords.y;
    };

    const handlePointerUpNative = (e: PointerEvent) => {
      if (!pointerState.current || !pointerState.current.isDown) return;
      const start = pointerState.current;
      pointerState.current = null;

      const coords = getCanvasCoords(e.clientX, e.clientY);
      const endX = coords ? coords.x : start.currentX;
      const endY = coords ? coords.y : start.currentY;

      const dx = endX - start.startX;
      const dy = endY - start.startY;
      const dist = Math.hypot(dx, dy);
      const duration = Date.now() - start.startTime;

      if (dist < 10) {
        // Precise atomic tap
        invoke("send_touch_tap", { x: endX, y: endY }).catch((err) => {
          setLogMsg(`Tap error: ${err}`);
        });
      } else {
        // Smooth interpolated swipe trajectory
        const dur = Math.max(100, Math.min(600, duration));
        invoke("send_touch_swipe", {
          x1: start.startX,
          y1: start.startY,
          x2: endX,
          y2: endY,
          durationMs: dur,
        }).catch((err) => {
          setLogMsg(`Swipe error: ${err}`);
        });
      }
    };

    // Use capture phase so we intercept before any child stops propagation
    container.addEventListener("pointerdown", handlePointerDownNative, { capture: true, passive: false });
    window.addEventListener("pointermove", handlePointerMoveNative, { capture: true, passive: true });
    window.addEventListener("pointerup", handlePointerUpNative, { capture: true, passive: false });
    window.addEventListener("pointercancel", handlePointerUpNative, { capture: true, passive: false });

    return () => {
      container.removeEventListener("pointerdown", handlePointerDownNative, { capture: true });
      window.removeEventListener("pointermove", handlePointerMoveNative, { capture: true });
      window.removeEventListener("pointerup", handlePointerUpNative, { capture: true });
      window.removeEventListener("pointercancel", handlePointerUpNative, { capture: true });
    };
  }, [connected, displayMode]);

  // Auto-connect when VNC port becomes ready in embedded mode
  useEffect(() => {
    if (displayMode === "embedded" && status.vnc_ready && !connected && !connecting && !rfbRef.current) {
      connectVNC();
    }
  }, [status.vnc_ready, displayMode]);

  // Auto-optimize animations and settings once ADB becomes available
  useEffect(() => {
    if (status.adb_ready && !optimized) {
      invoke("optimize_performance").catch(() => {});
      // Deploy zero-latency native touch daemon (writes directly to /dev/input/event*)
      invoke("deploy_touch_daemon")
        .then(() => setLogMsg("Touch daemon active — direct input enabled"))
        .catch(() => setLogMsg("Touch daemon not available, using ADB fallback"));
      setOptimized(true);
    } else if (!status.adb_ready) {
      setOptimized(false);
    }
  }, [status.adb_ready, optimized]);

  const handleStart = async () => {
    setLogMsg(`Launching Android QEMU VM in ${displayMode} mode...`);
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
          <h2>Android 16 ARM64</h2>
          <span
            className={`status-pill ${
              connected || (status.running && displayMode === "sdl")
                ? "connected"
                : status.running
                ? "booting"
                : "stopped"
            }`}
          >
            {connected
              ? "● Display Live (Embedded)"
              : status.running && displayMode === "sdl"
              ? "● Native SDL Window Active"
              : status.running
              ? "● Booting VM..."
              : "○ Stopped"}
          </span>
        </div>

        <div className="header-controls">
          {/* Mode Selector */}
          {!status.running && (
            <div className="mode-toggle">
              <label className={`mode-label ${displayMode === "embedded" ? "active" : ""}`}>
                <input
                  type="radio"
                  name="mode"
                  value="embedded"
                  checked={displayMode === "embedded"}
                  onChange={() => setDisplayMode("embedded")}
                />
                Embedded
              </label>
              <label className={`mode-label ${displayMode === "sdl" ? "active" : ""}`}>
                <input
                  type="radio"
                  name="mode"
                  value="sdl"
                  checked={displayMode === "sdl"}
                  onChange={() => setDisplayMode("sdl")}
                />
                Native SDL
              </label>
            </div>
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
        </div>
      </header>

      {/* Main Workspace: Screen Viewport + Android Control Bar */}
      <main className="main-viewport">
        <div className="screen-wrapper">
          {/* RFB Canvas mount point */}
          <div ref={screenRef} className="vnc-canvas-container" />

          {/* Placeholder overlay when not connected or in SDL mode */}
          {(!connected || displayMode === "sdl") && (
            <div className="screen-placeholder">
              {status.running && displayMode === "sdl" ? (
                <div className="placeholder-content">
                  <span className="device-icon">⚡</span>
                  <h3>Native GPU Window Running</h3>
                  <p>Android is rendering directly in a native SDL DirectX/OpenGL window at full 60 FPS.</p>
                  <p className="subtext">Use the toolbar on the right to send navigation and text input via ADB.</p>
                </div>
              ) : connecting || (status.running && !status.vnc_ready) ? (
                <div className="placeholder-content">
                  <div className="spinner" />
                  <h3>Booting Android System...</h3>
                  <p>Initializing Hypervisor (WHPX) & Guest Services</p>
                  <span className="subtext">Display will attach automatically once ready</span>
                </div>
              ) : (
                <div className="placeholder-content">
                  <span className="device-icon">📱</span>
                  <h3>Emulator Ready</h3>
                  <p>
                    Selected mode: <strong>{displayMode === "embedded" ? "In-App Embedded Display" : "Native SDL Window"}</strong>
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
