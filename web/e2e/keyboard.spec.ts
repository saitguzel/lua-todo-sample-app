import { test, expect } from "@playwright/test";
import { wait_for_app, login, create_user } from "./helpers";

test.describe("keyboard", () => {
  test("yalnızca klavye ile giriş (Enter gönderir)", async ({ page, request }) => {
    const u = await create_user(request);
    await page.goto("#/login");
    await wait_for_app(page);
    await page.getByLabel("E-posta").fill(u.email);
    await page.getByLabel("Parola", { exact: true }).fill(u.password);
    await page.keyboard.press("Enter");
    await expect(page).not.toHaveURL(/#\/login/);
  });

  test("n kısayolu yeni todo modalı açar; input içinde tetiklenmez", async ({ page, request }) => {
    const u = await create_user(request);
    await login(page, u.email, u.password);
    await page.getByRole("link", { name: "Todo'lar" }).click();
    await expect(page.getByRole("heading", { name: /Todo'lar/ })).toBeVisible(); // sayfa geçişi bitsin

    await page.keyboard.press("n");
    await expect(page.getByRole("dialog")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.getByRole("dialog")).toHaveCount(0);

    // arama kutusuna focus; n tuşu input'a yazılmalı, modal açmamalı
    await page.getByLabel("Ara", { exact: true }).focus();
    await page.keyboard.type("n");
    await expect(page.getByRole("dialog")).toHaveCount(0);
  });

  test("/ kısayolu arama kutusuna focus verir", async ({ page, request }) => {
    const u = await create_user(request);
    await login(page, u.email, u.password);
    await page.getByRole("link", { name: "Todo'lar" }).click();
    await expect(page.getByRole("heading", { name: /Todo'lar/ })).toBeVisible(); // sayfa geçişi bitsin
    await page.keyboard.press("/");
    await expect(page.getByLabel("Ara", { exact: true })).toBeFocused();
  });

  test("? kısayolu yardım modalını açar; Esc kapatır", async ({ page, request }) => {
    const u = await create_user(request);
    await login(page, u.email, u.password);
    await page.goto("#/todos");
    await page.keyboard.press("?");
    const help = page.getByRole("dialog", { name: "Klavye kısayolları" });
    await expect(help.getByText("Yeni todo")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(help).toHaveCount(0);
  });

  test("e/d kısayolları seçili todo üzerinde; silme onayında odak İptal; Esc sonrası odak geri döner", async ({ page, request }) => {
    const u = await create_user(request);
    await login(page, u.email, u.password);
    await page.goto("#/todos");
    const title = `kb-${Date.now()}`;
    await page.keyboard.press("n");
    await page.getByLabel("Başlık").fill(title);
    await page.getByRole("button", { name: "Ekle", exact: true }).click();
    const item = page.locator(`li[aria-label="${title}"]`);
    await expect(item).toBeVisible();

    await item.focus();
    await page.keyboard.press("e");
    await expect(page.getByRole("dialog", { name: "Todo düzenle" })).toBeVisible();
    await expect(page.getByLabel("Başlık")).toBeFocused(); // focus trap: ilk alan
    await page.keyboard.press("Escape");

    await item.focus();
    await page.keyboard.press("d");
    const confirm = page.getByRole("dialog", { name: "Silinsin mi?" });
    await expect(confirm.getByRole("button", { name: "İptal" })).toBeFocused();
    await page.keyboard.press("Escape");
    await expect(confirm).toHaveCount(0);
    await expect(item).toBeFocused();
  });
});
