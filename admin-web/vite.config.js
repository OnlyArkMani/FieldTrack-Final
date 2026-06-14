import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath, URL } from 'node:url';

// Dev proxy so the SPA and API share an origin in development (httpOnly refresh
// cookie is scoped to /api/v1/auth, so cross-origin would drop it).
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  server: {
    port: 5173,
    proxy: {
      // WebSocket upgrade — MUST be declared before the generic '/api' entry
      // (Vite matches in order; the more specific path has to win). ws:true is
      // what actually enables the HTTP→WS upgrade through the proxy.
      '/api/v1/ws': {
        target: process.env.VITE_PROXY_TARGET || 'http://localhost:8090',
        changeOrigin: true,
        ws: true,
      },
      '/api': {
        target: process.env.VITE_PROXY_TARGET || 'http://localhost:8090',
        changeOrigin: true,
        ws: true, // proxy the /ws/admin-live WebSocket too
      },
    },
  },
});
