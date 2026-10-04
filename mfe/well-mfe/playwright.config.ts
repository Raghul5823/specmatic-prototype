import { defineConfig, devices } from '@playwright/test';

/**
 * Browser tests of the MFE against a Specmatic STUB of well-registry.
 * Browser -> Angular dev server (:4200) -> dev-server proxy (/v2) -> Specmatic stub (:9101, strict, /v2).
 * The stub is started outside Playwright: see scripts/mfe-e2e.ps1 in the prototype root.
 */
export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  retries: 0,
  reporter: [
    ['list'],
    ['junit', { outputFile: 'test-results/junit.xml' }],
    ['html', { open: 'never', outputFolder: 'playwright-report' }],
  ],
  use: {
    baseURL: 'http://localhost:4200',
    trace: 'retain-on-failure',
  },
  // Chromium only (browser build 1234, already present on this machine for Playwright 1.62.1).
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: {
    // `npm start` regenerates the API client from the contract (prestart) and serves with the proxy.
    command: 'npm start -- --port 4200',
    url: 'http://localhost:4200',
    reuseExistingServer: false,
    timeout: 180_000,
    stdout: 'ignore',
    stderr: 'pipe',
  },
});
