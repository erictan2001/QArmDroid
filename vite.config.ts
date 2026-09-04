import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// @ts-expect-error process is a nodejs global
const host = process.env.TAURI_DEV_HOST;

// https://vite.dev/config/
export default defineConfig(async () => ({
  plugins: [react()],

  // Vite options tailored for Tauri development and only applied in `tauri dev` or `tauri build`
  //
  // 1. prevent Vite from obscuring rust errors
  clearScreen: false,
  // 2. tauri expects a fixed port, fail if that port is not available
  server: {
    port: 1420,
    strictPort: true,
    host: host || "127.0.0.1",
    hmr: host
      ? {
          protocol: "ws",
          host,
          port: 1421,
        }
      : undefined,
    watch: {
      // Ignore backend, toolchain, and heavy repository directories from Vite file watcher
      ignored: [
        "**/src-tauri/**",
        "**/tools/**",
        "**/angle-repo/**",
        "**/chromium-src/**",
        "**/aosp_cf_arm64_only_phone-img/**",
        "**/wsa-extracted/**",
        "**/research/**",
        "**/docs/**",
        "**/images/**",
        "**/work_sdk/**",
        "**/.git/**",
        "**/dist/**",
      ],
    },
  },
}));
