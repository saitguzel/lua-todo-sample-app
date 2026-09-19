import { test, expect } from "@playwright/test";
import { login, create_user } from "./helpers";

test.describe("responsive (mobil)", () => {
  test.use({ viewport: { width: 375, height: 667 } });

  test("360px genişlikte yatay kaydırma yok", async ({ page, request }) => {
    await page.setViewportSize({ width: 360, height: 740 });
    const adm = await create_user(request, "admin");
    await login(page, adm.email, adm.password);
    for (const h of ["#/", "#/todos", "#/users", "#/audit-logs", "#/profile"]) {
      await page.goto(h);
      await page.waitForTimeout(500);
      const ok = await page.evaluate(() =>
        document.documentElement.scrollWidth <= document.documentElement.clientWidth);
      expect(ok, h).toBe(true);
    }
  });

  test("hamburger menü açılır ve navigasyon çalışır", async ({ page, request }) => {
    const u = await create_user(request);
    await login(page, u.email, u.password);
    const burger = page.getByRole("button", { name: "Menüyü aç" });
    await expect(burger).toBeVisible();
    await burger.click();
    await page.getByRole("link", { name: "Todo'lar" }).click();
    await expect(page).toHaveURL(/#\/todos/);
  });
});
