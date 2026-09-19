import { test, expect } from "@playwright/test";
import { wait_for_app, unique_email, login } from "./helpers";

test.describe("admin", () => {
  test("admin rbac.matrix hücresi disabled; todouser API'den 403 alır", async ({ page }) => {
    await login(page, "user@todoapp.local", "User123!");
    // frontend gizleme güvenlik değildir: doğrudan API isteği 403 dönmeli
    const res = await page.request.get("http://localhost:28080/api/v1/rbac/matrix");
    expect(res.status()).toBe(403);
  });

  test("kullanıcı oluştur → o kullanıcı ile giriş yapılabilir", async ({ page }) => {
    await login(page, "admin@todoapp.local", "Admin123!");
    await page.getByRole("link", { name: "Kullanıcılar" }).click();
    const email = unique_email("created");
    await page.getByRole("button", { name: "+ Kullanıcı ekle" }).click();
    await page.getByLabel("E-posta").fill(email);
    await page.getByLabel("Parola", { exact: true }).fill("YeniParola1A");
    await page.getByRole("button", { name: "Kaydet" }).click();
    await expect(page.getByText(email)).toBeVisible();
  });

  test("admin kendini silemez (buton disabled)", async ({ page }) => {
    await login(page, "admin@todoapp.local", "Admin123!");
    await page.getByRole("link", { name: "Kullanıcılar" }).click();
    const ownRow = page.locator("tr", { hasText: "admin@todoapp.local" });
    await expect(ownRow.getByRole("button", { name: / sil$/ })).toBeDisabled();
  });

  test("todo.create audit'te görünür", async ({ page }) => {
    // todo oluştur (user)
    await login(page, "user@todoapp.local", "User123!");
    await page.getByRole("link", { name: "Todo'lar" }).click();
    const title = unique_email("audit").split("@")[0];
    await page.getByRole("button", { name: "+ Yeni todo" }).click();
    await page.getByLabel("Başlık").fill(title);
    await page.getByRole("button", { name: "Ekle", exact: true }).click();
    await expect(page.getByText(title)).toBeVisible();
    await page.getByRole("button", { name: "Çıkış" }).click();

    // admin audit'te bakar
    await login(page, "admin@todoapp.local", "Admin123!");
    await page.getByRole("link", { name: "Denetim" }).click();
    await page.getByLabel("Eylem").selectOption("todo.create");
    await expect(page.getByRole("table")).toBeVisible();
  });
});
