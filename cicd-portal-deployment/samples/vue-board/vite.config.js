import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

// npm run dev: /api goes to a local backend (node-board: 8080 by default; spring-board: also 8080)
export default defineConfig({
  plugins: [vue()],
  server: {
    proxy: {
      '/api': process.env.VITE_API_TARGET || 'http://127.0.0.1:8080',
    },
  },
});
