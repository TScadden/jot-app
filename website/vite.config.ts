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
        resetPassword: resolve(__dirname, 'reset-password.html'),
        login: resolve(__dirname, 'login.html'),
        auth: resolve(__dirname, 'auth.ts'),
        onboarding: resolve(__dirname, 'onboarding.html'),
        onboardingScript: resolve(__dirname, 'onboarding.ts'),
        dashboard: resolve(__dirname, 'dashboard.html'),
        privacy: resolve(__dirname, 'privacy.html'),
      },
    },
  },
});
