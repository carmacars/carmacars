import { existsSync } from 'node:fs';
import { defineConfig } from '@playwright/test';

// End-to-end tests against the local stack (scripts/local-db.sh) and the local production server
// (scripts/serve.mjs, which adds the same security headers and nonce as the Worker entry).
// Run `npm run build` first. Two widths: 375 (phone) and 1440 (desktop).
// the browsers of this machine when present; otherwise Playwright's own cache (CI caches ~/.cache/ms-playwright)
if (!process.env.PLAYWRIGHT_BROWSERS_PATH && existsSync('/opt/pw-browsers')) process.env.PLAYWRIGHT_BROWSERS_PATH = '/opt/pw-browsers';
const base = process.env.BASE_URL ?? 'http://localhost:3000';

export default defineConfig({
  testDir: 'tests/e2e',
  timeout: 60_000,
  fullyParallel: false,
  workers: 2,
  // CI: one retry, so a test that fails only under the runner's load is reported as flaky (it still has to pass once);
  // a defect fails both tries. Local runs never retry.
  retries: process.env.CI ? 1 : 0,
  reporter: [['list'], ['json', { outputFile: 'reports/e2e.json' }]],
  use: { baseURL: base, trace: 'retain-on-failure', launchOptions: { args: ['--no-proxy-server'] } },
  projects: [
    { name: 'phone-375', use: { viewport: { width: 375, height: 812 }, isMobile: false, hasTouch: true } },
    { name: 'desktop-1440', use: { viewport: { width: 1440, height: 900 } } }
  ],
  webServer: process.env.BASE_URL ? undefined : { command: 'node scripts/serve.mjs', url: base, reuseExistingServer: true, timeout: 60_000 }
});
