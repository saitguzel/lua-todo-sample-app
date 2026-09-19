import { test, expect } from "@playwright/test";
import { wait_for_app, unique_email, login, logout } from "./helpers";

test.describe("auth", () => {
  test("admin girişi başarılı", async ({ page }) => {
    await page.goto("#/login");
    await wait_for_app(page);
    await page.getByLabel("E-posta").fill("admin@todoapp.local");
    await page.getByLabel("Parola", { exact: true }).fill("Admin123!");
    await page.getByRole("button", { name: "Giriş yap" }).click();
    await expect(page).toHaveURL(/#\/$/);
  });

  test("hatalı parola: e-posta varlığı ifşa edilmez", async ({ page }) => {
    await page.goto("#/login");
    await wait_for_app(page);
    await page.getByLabel("E-posta").fill("admin@todoapp.local");
    await page.getByLabel("Parola", { exact: true }).fill("yanlis-parola-1A");
    await page.getByRole("button", { name: "Giriş yap" }).click();
    await expect(page.getByRole("alert")).toContainText("E-posta veya parola hatalı");
  });

  test("oturum yenilemede korunur", async ({ page }) => {
    await login(page, "user@todoapp.local", "User123!");
    await page.reload();
    await wait_for_app(page);
    await expect(page).not.toHaveURL(/#\/login/);
  });

  test("logout sonrası korumalı sayfaya girilemez", async ({ page }) => {
    await login(page, "user@todoapp.local", "User123!");
    await logout(page);
    await page.goto("#/todos");
    await expect(page).toHaveURL(/#\/login\?next=/);
  });

  test("todouser menüsünde admin öğeleri görünmez", async ({ page }) => {
    await login(page, "user@todoapp.local", "User123!");
    await expect(page.getByRole("link", { name: "Kullanıcılar" })).toHaveCount(0);
    await expect(page.getByRole("link", { name: "Yetkiler" })).toHaveCount(0);
    await expect(page.getByRole("link", { name: "Denetim" })).toHaveCount(0);
  });
});
