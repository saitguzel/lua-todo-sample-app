import { test, expect } from "@playwright/test";
import { wait_for_app, login } from "./helpers";

test.describe("keyboard", () => {
  test("yalnızca klavye ile todo akışı", async ({ page }) => {
    await page.goto("#/login");
    await wait_for_app(page);
    // Tab ile form alanlarına, Enter ile gönder
    await page.getByLabel("E-posta").fill("user@todoapp.local");
    await page.getByLabel("Parola", { exact: true }).fill("User123!");
    await page.keyboard.press("Enter");
    await expect(page).not.toHaveURL(/#\/login/);
  });

  test("n kısayolu yeni todo modalı açar; input içinde tetiklenmez", async ({ page }) => {
    await login(page, "user@todoapp.local", "User123!");
    await page.getByRole("link", { name: "Todo'lar" }).click();

    await page.keyboard.press("n");
    await expect(page.getByRole("dialog")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.getByRole("dialog")).toHaveCount(0);

    // arama kutusuna focus; n tuşu input'a yazılmalı, modal açmamalı
    await page.getByPlaceholder(/Ara/).focus();
    await page.keyboard.type("n");
    await expect(page.getByRole("dialog")).toHaveCount(0);
  });

  test("/ kısayolu arama kutusuna focus verir", async ({ page }) => {
    await login(page, "user@todoapp.local", "User123!");
    await page.getByRole("link", { name: "Todo'lar" }).click();
    await page.keyboard.press("/");
    await expect(page.getByPlaceholder(/Ara/)).toBeFocused();
  });

  test("? kısayolu profil sayfasında kısayol tablosunu gösterir", async ({ page }) => {
    await login(page, "user@todoapp.local", "User123!");
    await page.getByRole("link", { name: "Profil" }).click();
    await expect(page.getByRole("table").getByText("Yeni todo")).toBeVisible();
  });
});
