import { test, expect } from "@playwright/test";
import { ADMIN, login, logout, unique_email, create_user } from "./helpers";

test.describe("admin: kullanıcılar", () => {
  test("kullanıcı oluştur → o kullanıcıyla giriş yapılır", async ({ page, request }) => {
    const adm = await create_user(request, "admin");
    await login(page, adm.email, adm.password);
    await page.getByRole("link", { name: "Kullanıcılar" }).click();
    const email = unique_email("created");
    await page.getByRole("button", { name: "+ Kullanıcı ekle" }).click();
    const dialog = page.getByRole("dialog", { name: "Yeni kullanıcı" });
    await dialog.getByLabel("E-posta").fill(email);
    await dialog.getByLabel("Parola", { exact: true }).fill("YeniParola1!");
    await dialog.getByRole("button", { name: "Kaydet" }).click();
    await expect(dialog).toHaveCount(0);
    await page.getByLabel("Ara", { exact: true }).fill(email); // liste sayfalı: aramayla bul
    await expect(page).toHaveURL(/q=/);
    await expect(page.getByRole("rowheader", { name: email })).toBeVisible();

    await logout(page);
    await login(page, email, "YeniParola1!");
  });

  test("aynı e-posta → EMAIL_TAKEN alan hatası", async ({ page, request }) => {
    const adm = await create_user(request, "admin");
    await login(page, adm.email, adm.password);
    await page.getByRole("link", { name: "Kullanıcılar" }).click();
    await page.getByRole("button", { name: "+ Kullanıcı ekle" }).click();
    const dialog = page.getByRole("dialog", { name: "Yeni kullanıcı" });
    await dialog.getByLabel("E-posta").fill(ADMIN.email);
    await dialog.getByLabel("Parola", { exact: true }).fill("YeniParola1!");
    await dialog.getByRole("button", { name: "Kaydet" }).click();
    await expect(dialog.getByText("Bu e-posta zaten kullanılıyor")).toBeVisible();
    await expect(dialog.getByLabel("E-posta")).toBeFocused();
  });

  test("admin kendini silemez (buton disabled)", async ({ page, request }) => {
    const adm = await create_user(request, "admin");
    await login(page, adm.email, adm.password);
    await page.goto(`#/users?q=${encodeURIComponent(adm.email)}`);
    await expect(page.getByRole("button", { name: `${adm.email} sil` })).toBeDisabled();
  });
});
