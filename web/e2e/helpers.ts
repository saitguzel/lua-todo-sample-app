import { Page, expect } from "@playwright/test";

// Wasmoon hazır olana kadar bekle (keyfi sleep yok — html[data-ready])
export async function wait_for_app(page: Page): Promise<void> {
  await page.waitForSelector("html[data-ready='1']", { timeout: 30_000 });
}

// Her test kendi benzersiz verisini üretir (paralel/izole — DB reset endpoint'i yok)
export function unique_email(prefix = "e2e"): string {
  return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}@todoapp.local`;
}

export async function login(page: Page, email: string, password: string): Promise<void> {
  await page.goto("#/login");
  await wait_for_app(page);
  await page.getByLabel("E-posta").fill(email);
  await page.getByLabel("Parola", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Giriş yap" }).click();
  await expect(page.getByRole("heading", { name: "Pano" })).toBeVisible({ timeout: 15_000 });
}

export async function logout(page: Page): Promise<void> {
  await page.getByRole("button", { name: "Çıkış" }).click();
  await expect(page).toHaveURL(/#\/login/);
}
