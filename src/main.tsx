import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";

console.log("[QArmDroid] main.tsx executing, mounting React root...");
const rootEl = document.getElementById("root");
if (!rootEl) {
  console.error("[QArmDroid] FATAL: #root element not found in DOM!");
} else {
  try {
    ReactDOM.createRoot(rootEl).render(
      <React.StrictMode>
        <App />
      </React.StrictMode>,
    );
    console.log("[QArmDroid] React root rendered.");
  } catch (err) {
    console.error("[QArmDroid] FATAL: Failed to render React tree:", err);
  }
}
