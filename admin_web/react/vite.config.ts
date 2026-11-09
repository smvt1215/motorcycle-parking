import react from '@vitejs/plugin-react';
import { defineConfig } from 'vitest/config';

export default defineConfig(({ command, mode }) => ({
  plugins: [react()],
  // Deployed under the Flutter admin's Hosting site at /pending; the fixture
  // build and the dev server stay at the root.
  base: command === 'build' && mode === 'production' ? '/pending/' : '/',
  build: {
    outDir: 'dist',
    sourcemap: true,
  },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/test/setup.ts'],
    css: true,
  },
}));
