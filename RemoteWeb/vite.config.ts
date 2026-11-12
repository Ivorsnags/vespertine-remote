import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The phone page. Built into site/ and served by the Mac app on the local network, never from the internet.
export default defineConfig({
  base: '/',
  plugins: [react()],
  build: {
    outDir: 'site',
    emptyOutDir: true,
    assetsDir: 'assets',
    target: 'safari16',
    chunkSizeWarningLimit: 600,
  },
})
