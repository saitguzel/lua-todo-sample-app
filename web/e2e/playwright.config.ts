import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  timeout: 30_000,
  retries: process.env.CI ? 2 : 0,
  use: {
    baseURL: process.env.WEB_BASE_URL ?? "http://localhost:28000",
    trace: "retain-on-failure",
  },
  projects: [
    { name: "chromium", use: devices["Desktop Chrome"] },
    { name: "firefox", use: devices["Desktop Firefox"] },
    { name: "webkit", use: devices["Desktop Safari"] },
    { name: "mobile", use: devices["Pixel 7"] },
    // Yerel koşu: indirilmiş Playwright tarayıcısı yerine sistem Chrome'u (PW_CHANNEL=chrome --project=local)
    ...(process.env.PW_CHANNEL ? [{ name: "local", use: { ...devices["Desktop Chrome"], channel: process.env.PW_CHANNEL } }] : []),
  ],
});
