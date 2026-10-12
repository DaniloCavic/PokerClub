import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Admin panel se servira sa servera na /admin; u razvoju se /api prosleđuje serveru.
export default defineConfig({
  base: '/admin/',
  plugins: [react()],
  server: {
    port: 5173,
    proxy: { "/api": "http://localhost:3000" },
  },
});
