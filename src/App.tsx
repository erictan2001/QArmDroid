import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import "./App.css";

function App() {
  const [status, setStatus] = useState("Ready");
  const [imagePath, setImagePath] = useState("");

  async function startEmulator() {
    setStatus("Starting...");
    try {
      const result = await invoke("start_emulator", { imagePath: imagePath || null });
      setStatus(result as string);
    } catch (error) {
      setStatus(`Error: ${error}`);
    }
  }

  return (
    <main className="container">
      <h1>ARM64 Android Emulator</h1>
      
      <div className="card">
        <h3>Control Panel</h3>
        <p>Status: <strong>{status}</strong></p>
        
        <div className="row">
          <input
            id="image-input"
            onChange={(e) => setImagePath(e.currentTarget.value)}
            placeholder="Path to Android Image (optional)..."
            style={{ width: "300px" }}
          />
          <button onClick={startEmulator}>Start Emulator</button>
        </div>
        
        <div className="info">
          <p>Configured for <strong>Snapdragon X Elite (ARM64)</strong></p>
          <ul>
            <li>Hypervisor: WHPX (Native)</li>
            <li>GPU: VirtIO Venus (Vulkan Accelerated)</li>
            <li>Engine: QEMU 11.0.0 (Native)</li>
          </ul>
        </div>
      </div>
      
      <div className="footer">
        <p>Open Source ARM64 Emulator Project</p>
      </div>
    </main>
  );
}

export default App;
