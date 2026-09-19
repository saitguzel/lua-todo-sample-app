import { test, expect } from "@playwright/test";
import { ADMIN, API, login, logout, create_user, api_token, set_permission } from "./helpers";

// Matris global durumdur: bu dosyadaki testler sırayla koşar
test.describe.serial("admin: yetki matrisi", () => {
  test("admin'in rbac.matrix hücresi kilitli (disabled)", async ({ page, request }) => {
    const adm = await create_user(request, "admin");
    await login(page, adm.email, adm.password);
    await page.getByRole("link", { name: "Yetkiler" }).click();
    await expect(page.getByRole("checkbox", { name: "admin rolü için rbac.matrix erişimi" })).toBeDisabled();
  });

  test("todouser'a users.list verilince menüde görünür (reload sonrası)", async ({ page, request }) => {
    const user = await create_user(request);
    try {
      const adm = await create_user(request, "admin");
    await login(page, adm.email, adm.password);
      await page.getByRole("link", { name: "Yetkiler" }).click();
      const cell = page.getByRole("checkbox", { name: "todouser rolü için users.list erişimi" });
      await cell.check();
      await expect(page.locator("#toast-polite")).toContainText("users.list");
      await logout(page);

      await login(page, user.email, user.password);
      await page.reload();
      await expect(page.getByRole("link", { name: "Kullanıcılar" })).toBeVisible();
    } finally {
      await set_permission(request, "todouser", "users.list", false);
    }
  });

  test("todouser admin API'sine doğrudan istekte 403 alır (gizleme güvenlik değildir)", async ({ request }) => {
    const user = await create_user(request);
    const token = await api_token(request, user.email, user.password);
    const res = await request.get(`${API}/rbac/matrix`, { headers: { Authorization: `Bearer ${token}` } });
    expect(res.status()).toBe(403);
    expect((await res.json()).error.code).toBe("FORBIDDEN");
  });

  test("todouser #/rbac → 'yetkiniz yok' içeriği, admin bundle'ı indirilmez", async ({ page, request }) => {
    const user = await create_user(request);
    const adminBundle: string[] = [];
    page.on("request", (r) => { if (r.url().includes("bundle-admin")) adminBundle.push(r.url()); });
    await login(page, user.email, user.password);
    await page.goto("#/rbac");
    await expect(page.getByRole("heading", { name: "Bu sayfaya erişim yetkiniz yok" })).toBeVisible();
    expect(adminBundle).toEqual([]);
  });
});
