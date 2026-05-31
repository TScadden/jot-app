import { defineConfig } from 'vite';
import { resolve } from 'path';

export default defineConfig({
  root: './',
  build: {
    target: 'es2022',
    cssTarget: 'chrome100',
    rollupOptions: {
      input: {
        main: resolve(__dirname, 'index.html'),
        learnMore: resolve(__dirname, 'learn-more.html'),
      },
    },
  },
});
