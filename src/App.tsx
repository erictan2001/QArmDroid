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

  // Connect to VNC WebSocket
  const connectVNC = () => {
    if (!screenRef.current) return;
    if (rfbRef.current) {
      try {
        rfbRef.current.disconnect();
      } catch {}
      rfbRef.current = null;
    }

    setConnecting(true);
    setLogMsg("Connecting to display stream (ws://127.0.0.1:5901)...");

    try {
      const rfb = new RFB(screenRef.current, "ws://127.0.0.1:5901");
      rfb.scaleViewport = true;
      rfb.resizeSession = false;
      rfb.clipViewport = false;
      rfb.focusOnClick = true;
      rfb.background = "#0f172a";

      rfb.addEventListener("connect", () => {
        setConnecting(false);
        setConnected(true);
        setLogMsg("Connected to Android display");
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

  // Auto-connect when VNC port becomes ready
  useEffect(() => {
    if (status.vnc_ready && !connected && !connecting && !rfbRef.current) {
      connectVNC();
    }
  }, [status.vnc_ready]);

  const handleStart = async () => {
    setLogMsg("Launching Android QEMU VM...");
    try {
      const msg = await invoke<string>("start_emulator");
      setLogMsg(msg);
      // Wait slightly then check status
      setTimeout(async () => {
        const s = await checkStatus();
        if (s.vnc_ready) connectVNC();
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
      // Escape spaces for ADB input
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
              connected
                ? "connected"
                : status.running
                ? "booting"
                : "stopped"
            }`}
          >
            {connected
              ? "● Display Live"
              : status.running
              ? "● Booting VM..."
              : "○ Stopped"}
          </span>
        </div>

        <div className="header-controls">
          {!status.running ? (
            <button className="btn btn-primary" onClick={handleStart}>
              ▶ Launch Emulator
            </button>
          ) : (
            <button className="btn btn-danger" onClick={handleStop}>
              ■ Stop Emulator
            </button>
          )}

          {status.vnc_ready && !connected && (
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

          {/* Placeholder overlay when not connected */}
          {!connected && (
            <div className="screen-placeholder">
              {connecting || (status.running && !status.vnc_ready) ? (
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
                  <p>Click <strong>Launch Emulator</strong> to start Android 16</p>
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
              <div>Display WS: <strong>ws://127.0.0.1:5901</strong></div>
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
