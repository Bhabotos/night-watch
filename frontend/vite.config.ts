import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    // Dev only: the production proxy is nginx (nginx/nginx.conf).
    proxy: { "/api": "http://localhost:8000" },
  },
  build: {
    outDir: "dist",
    sourcemap: false,
    // The nginx CSP forbids inline scripts/styles, so never inline assets.
    assetsInlineLimit: 0,
  },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./src/test/setup.ts"],
    css: false,
  },
});
