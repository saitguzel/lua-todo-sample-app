import { test, expect } from "@playwright/test";
import { wait_for_app, login } from "./helpers";

test.describe("responsive (mobil)", () => {
  test.use({ viewport: { width: 375, height: 667 } });

  test("360px genişlikte yatay kaydırma yok", async ({ page }) => {
    await page.setViewportSize({ width: 360, height: 740 });
    await login(page, "user@todoapp.local", "User123!");
    const scroll = await page.evaluate(() =>
      document.documentElement.scrollWidth <= document.documentElement.clientWidth);
    expect(scroll).toBe(true);
  });

  test("hamburger menü açılır ve navigasyon çalışır", async ({ page }) => {
    await login(page, "user@todoapp.local", "User123!");
    const burger = page.getByRole("button", { name: "Menüyü aç" });
    await expect(burger).toBeVisible();
    await burger.click();
    await page.getByRole("link", { name: "Todo'lar" }).click();
    await expect(page).toHaveURL(/#\/todos/);
  });
});
