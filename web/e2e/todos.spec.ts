import { test, expect } from "@playwright/test";
import { wait_for_app, unique_email, login } from "./helpers";

test.describe("todos", () => {
  test("oluştur → listede görünür → tamamlanır → silinir", async ({ page }) => {
    await login(page, "user@todoapp.local", "User123!");
    await page.getByRole("link", { name: "Todo'lar" }).click();

    const title = unique_email("todo").split("@")[0];
    await page.getByRole("button", { name: "+ Yeni todo" }).click();
    await page.getByLabel("Başlık").fill(title);
    await page.getByRole("button", { name: "Ekle", exact: true }).click();
    await expect(page.getByText(title)).toBeVisible();

    // tamamla (checkbox) → PATCH
    const row = page.locator(`.todo-item`, { hasText: title });
    await row.getByRole("checkbox").check();
    await expect(row.locator(".line-through")).toBeVisible();

    // sil (onaylı)
    await row.getByRole("button", { name: new RegExp(`${title} sil`) }).click();
    await page.getByRole("button", { name: "Sil", exact: true }).click();
    await expect(page.locator(".todo-item", { hasText: title })).toHaveCount(0);
  });

  test("API hatasında optimistic rollback", async ({ page }) => {
    await login(page, "user@todoapp.local", "User123!");
    await page.getByRole("link", { name: "Todo'lar" }).click();

    // API'yi 500'e zorla (F17: rollback + toast kanıtı)
    await page.route("**/api/v1/todos", (route) =>
      route.fulfill({ status: 500, body: JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "hata" } }) }));

    const title = unique_email("roll").split("@")[0];
    await page.getByRole("button", { name: "+ Yeni todo" }).click();
    await page.getByLabel("Başlık").fill(title);
    await page.getByRole("button", { name: "Ekle", exact: true }).click();

    // satır geri gelir (kaldırılır) + hata toast'u
    await expect(page.locator(".todo-item", { hasText: title })).toHaveCount(0);
    await expect(page.locator(".toast")).toBeVisible();
  });

  test("filtreler URL'ye yansır", async ({ page }) => {
    await login(page, "user@todoapp.local", "User123!");
    await page.getByRole("link", { name: "Todo'lar" }).click();
    await page.getByLabel("Durum").selectOption("pending");
    await expect(page).toHaveURL(/status=pending/);
  });
});
