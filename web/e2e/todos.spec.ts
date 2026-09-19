import { test, expect } from "@playwright/test";
import { unique_email, login, create_user, API, api_token } from "./helpers";

test.describe("todos", () => {
  test("oluştur → listede görünür → tamamlanır → silinir", async ({ page, request }) => {
    const u = await create_user(request);
    await login(page, u.email, u.password);
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
    await row.getByRole("button", { name: `'${title}' sil` }).click();
    await page.getByRole("button", { name: "Sil", exact: true }).click();
    await expect(page.locator(".todo-item", { hasText: title })).toHaveCount(0);
  });

  test("API hatasında optimistic rollback", async ({ page, request }) => {
    const u = await create_user(request);
    await login(page, u.email, u.password);
    await page.getByRole("link", { name: "Todo'lar" }).click();

    // API'yi 500'e zorla (F17: rollback + toast kanıtı)
    await page.route("**/api/v1/todos", (route) =>
      route.fulfill({ status: 500, body: JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "hata" } }) }));

    const title = unique_email("roll").split("@")[0];
    await page.getByRole("button", { name: "+ Yeni todo" }).click();
    await page.getByLabel("Başlık").fill(title);
    await page.getByRole("button", { name: "Ekle", exact: true }).click();

    // optimistic satır geri alınır + hata toast'u (assertive bölge)
    await expect(page.locator(".todo-item", { hasText: title })).toHaveCount(0);
    await expect(page.locator("#toast-assertive .toast")).toBeVisible();
  });

  test("filtreler URL'ye yansır; geri tuşu önceki filtreye döner", async ({ page, request }) => {
    const u = await create_user(request);
    await login(page, u.email, u.password);
    await page.getByRole("link", { name: "Todo'lar" }).click();
    await page.getByLabel("Durum").selectOption("pending");
    await expect(page).toHaveURL(/status=pending/);
    await page.getByLabel("Öncelik").selectOption("high");
    await expect(page).toHaveURL(/priority=high/);
    await page.goBack();
    await expect(page).not.toHaveURL(/priority=high/);
    await expect(page.getByLabel("Öncelik")).toHaveValue("");
  });

  test("başka kullanıcının todo id'si → bulunamadı", async ({ page, request }) => {
    const other = await create_user(request);
    const token = await api_token(request, other.email, other.password);
    const res = await request.post(`${API}/todos`, { headers: { Authorization: `Bearer ${token}` }, data: { title: "gizli" } });
    const id = (await res.json()).data.id;

    const u = await create_user(request);
    await login(page, u.email, u.password);
    await page.goto(`#/todos/${id}`);
    await expect(page.locator("#toast-assertive")).toContainText("Todo bulunamadı");
    await expect(page).toHaveURL(/#\/todos(\?|$)/);
  });

  test("boş durum: filtre sonucu yoksa 'Filtreleri temizle'", async ({ page, request }) => {
    const u = await create_user(request);
    await login(page, u.email, u.password);
    await page.goto(`#/todos?q=${encodeURIComponent("yok-" + Date.now())}`);
    await expect(page.getByRole("heading", { name: "Sonuç yok" })).toBeVisible();
    await page.getByRole("button", { name: "Filtreleri temizle" }).click();
    await expect(page).toHaveURL(/#\/todos$/);
  });
});
