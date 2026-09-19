import { test, expect } from "@playwright/test";
import { ADMIN, login, logout, create_user, unique_email } from "./helpers";
import { readFileSync } from "node:fs";

test.describe("admin: denetim kayıtları", () => {
  test("todo oluştur → audit'te todo.create; filtre URL'de; detay diff; CSV", async ({ page, request }) => {
    const user = await create_user(request);
    await login(page, user.email, user.password);
    await page.goto("#/todos");
    const title = unique_email("audit").split("@")[0];
    await page.getByRole("button", { name: "+ Yeni todo" }).click();
    await page.getByLabel("Başlık").fill(title);
    await page.getByRole("button", { name: "Ekle", exact: true }).click();
    await expect(page.getByText(title)).toBeVisible();
    // güncelle → todo.update (detayda diff görünsün)
    await page.getByRole("button", { name: `'${title}' düzenle` }).click();
    await page.getByLabel("Başlık").fill(title + "-v2");
    await page.getByRole("button", { name: "Kaydet" }).click();
    await expect(page.getByText(title + "-v2")).toBeVisible();
    await logout(page);

    const adm = await create_user(request, "admin");
    await login(page, adm.email, adm.password);
    await page.getByRole("link", { name: "Denetim" }).click();
    await expect(page).toHaveURL(/from=/); // varsayılan son 7 gün
    await page.getByLabel("Eylem").selectOption("todo.update");
    await expect(page).toHaveURL(/action=todo\.update/);
    await page.getByLabel("Kullanıcı e-postası").fill(user.email);
    await expect(page).toHaveURL(/user_email=/);

    const row = page.locator("tbody tr[aria-haspopup]").first();
    await row.click();
    const detail = page.getByRole("dialog", { name: /todo\.update/ });
    await expect(detail.getByText("(değişti)").first()).toBeAttached();
    await page.keyboard.press("Escape");
    await expect(detail).toHaveCount(0);

    const [download] = await Promise.all([
      page.waitForEvent("download"),
      page.getByRole("button", { name: "CSV indir" }).click(),
    ]);
    const csv = readFileSync(await download.path(), "utf8");
    expect(csv.split("\n").filter(Boolean).length).toBeGreaterThanOrEqual(2); // başlık + ≥1 satır
  });

  test("bitiş < başlangıç reddedilir", async ({ page, request }) => {
    const adm = await create_user(request, "admin");
    await login(page, adm.email, adm.password);
    await page.goto("#/audit-logs");
    await page.getByLabel("Bitiş").fill("2000-01-01");
    await expect(page.getByText("Bitiş tarihi başlangıçtan önce olamaz")).toBeVisible();
  });
});
