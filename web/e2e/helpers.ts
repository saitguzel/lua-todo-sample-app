import { APIRequestContext, Page, expect } from "@playwright/test";

// API adresi (frontend'den bağımsız doğrudan istekler: izin/403 kanıtı, test verisi kurulumu)
export const API = process.env.API_BASE_URL ?? "http://localhost:28080/api/v1";
export const ADMIN = { email: "admin@todoapp.local", password: "Admin123!" };
export const USER = { email: "user@todoapp.local", password: "User123!" };

// Wasmoon hazır olana kadar bekle (keyfi sleep yok — html[data-ready])
export async function wait_for_app(page: Page): Promise<void> {
  await page.waitForSelector("html[data-ready='1']", { timeout: 30_000 });
}

// Her test kendi benzersiz verisini üretir (paralel/izole — DB reset endpoint'i yok)
export function unique_email(prefix = "e2e"): string {
  return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}@todoapp.local`;
}

export async function login(page: Page, email: string, password: string): Promise<void> {
  await page.goto("#/login");
  await wait_for_app(page);
  await page.getByLabel("E-posta").fill(email);
  await page.getByLabel("Parola", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Giriş yap" }).click();
  await expect(page.getByRole("heading", { name: "Pano" })).toBeVisible({ timeout: 15_000 });
}

export async function logout(page: Page): Promise<void> {
  await page.getByRole("button", { name: "Çıkış", exact: true }).click();
  await expect(page).toHaveURL(/#\/login/);
}

// API üzerinden access token (UI'dan bağımsız kurulum/doğrulama için)
export async function api_token(request: APIRequestContext, email: string, password: string): Promise<string> {
  const res = await request.post(`${API}/auth/login`, { data: { email, password } });
  expect(res.ok(), `login ${email}: ${res.status()}`).toBeTruthy();
  return (await res.json()).data.access_token;
}

// Seed admin token'ı worker başına önbellekte (login rate limit'ine takılmamak için; TTL'den önce yenilenir)
let admin_cache: { token: string; at: number } | null = null;
export async function admin_token(request: APIRequestContext): Promise<string> {
  if (!admin_cache || Date.now() - admin_cache.at > 45_000) {
    admin_cache = { token: await api_token(request, ADMIN.email, ADMIN.password), at: Date.now() };
  }
  return admin_cache.token;
}

// Admin API'siyle geçici kullanıcı oluşturur: her test kendi hesabıyla koşar (izole, paralel güvenli;
// seed hesaplarının parolası/durumu testlerde değişmez)
export async function create_user(request: APIRequestContext, role = "todouser"): Promise<{ email: string; password: string }> {
  const token = await admin_token(request);
  const user = { email: unique_email(role), password: "E2eParola1!" };
  const res = await request.post(`${API}/users`, {
    headers: { Authorization: `Bearer ${token}` },
    data: { ...user, role, full_name: "E2E Kullanıcı" },
  });
  expect(res.status(), await res.text()).toBe(201);
  return user;
}

// RBAC hücresini API ile ayarlar (admin-rbac testi sonunda eski haline döndürür)
export async function set_permission(request: APIRequestContext, role: string, page_key: string, can_access: boolean) {
  const token = await admin_token(request);
  const res = await request.patch(`${API}/rbac/matrix/${role}/${page_key}`, {
    headers: { Authorization: `Bearer ${token}` }, data: { can_access },
  });
  expect(res.ok(), await res.text()).toBeTruthy();
}
