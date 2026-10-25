import { defineConfig } from 'vite'

// The engine ships large .wasm modules; keep them as separate cacheable files
// instead of letting Vite inline anything, and never pre-bundle the engine
// package (its Emscripten glue resolves sibling files at runtime).
export default defineConfig({
  base: '/',
  build: {
    target: 'es2022',
    assetsInlineLimit: 0,
    chunkSizeWarningLimit: 8000,
    sourcemap: false,
    rollupOptions: {
      input: {
        index: 'index.html', // dashboard phòng
        play: 'play.html', // trang chơi
      },
    },
  },
  server: {
    host: true,
    port: 5173,
  },
})
