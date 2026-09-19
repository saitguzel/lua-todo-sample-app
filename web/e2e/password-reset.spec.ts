import { test, expect } from "@playwright/test";
import { wait_for_app, unique_email, create_user, login } from "./helpers";

// MailHog API (docker-compose'da 127.0.0.1:28025)
const MAILHOG = "http://127.0.0.1:28025";

test.describe("password reset", () => {
  test("forgot → MailHog linki → reset → yeni parola ile login", async ({ page, request }) => {
    test.skip(process.env.CI !== "true" && !(await request.get(MAILHOG + "/api/v2/messages").catch(() => null))?.ok(),
      "MailHog çalışmıyor");

    // seed hesabının parolası değişmesin: geçici kullanıcı
    const user = await create_user(request);
    await page.goto("#/forgot-password");
    await wait_for_app(page);
    await page.getByLabel("E-posta").fill(user.email);
    await page.getByRole("button", { name: "Sıfırlama bağlantısı gönder" }).click();
    await expect(page.getByText("Bağlantı gönderildi")).toBeVisible();

    // MailHog'dan bu kullanıcıya giden mesajı bul. Gövde MIME multipart; parçalar base64 veya
    // quoted-printable olabilir → base64 blokları çözülür, QP soft break'leri temizlenir.
    let token = "";
    await expect.poll(async () => {
      const q = await (await request.get(`${MAILHOG}/api/v2/search?kind=to&query=${encodeURIComponent(user.email)}`)).json();
      const raw: string = q.items?.[0]?.Content?.Body ?? "";
      const decoded = (raw.match(/(?:[A-Za-z0-9+/]{60,}={0,2}\r?\n?)+/g) ?? [])
        .map((b) => Buffer.from(b.replace(/\s/g, ""), "base64").toString("utf8")).join("\n");
      const text = (raw + "\n" + decoded).replace(/=\r?\n/g, "").replace(/=3D/g, "=");
      token = text.match(/reset-password\?token=([0-9a-f]{64})/)?.[1] ?? "";
      return token;
    }, { timeout: 10_000 }).not.toBe("");

    // reset sayfası: token URL'den silinmeli (history.replaceState)
    const link = `#/reset-password?token=${token}`;
    await page.goto(link);
    await wait_for_app(page);
    await expect(page).not.toHaveURL(/token=/);
    await page.getByLabel("Yeni parola", { exact: true }).fill("YeniParola2B!");
    await page.getByLabel("Parolayı onayla").fill("YeniParola2B!");
    await page.getByRole("button", { name: "Parolayı güncelle" }).click();
    await expect(page.getByRole("heading", { name: "Parolanız güncellendi" })).toBeVisible();

    // aynı link ikinci kez → hata
    await page.goto(link);
    await page.getByLabel("Yeni parola", { exact: true }).fill("Baska1234!");
    await page.getByLabel("Parolayı onayla").fill("Baska1234!");
    await page.getByRole("button", { name: "Parolayı güncelle" }).click();
    await expect(page.getByText(/süresi dolmuş veya kullanılmış/)).toBeVisible();

    // yeni parola ile giriş
    await login(page, user.email, "YeniParola2B!");
  });

  test("kayıtsız e-posta aynı başarı mesajını alır", async ({ page }) => {
    await page.goto("#/forgot-password");
    await wait_for_app(page);
    await page.getByLabel("E-posta").fill(unique_email("ghost"));
    await page.getByRole("button", { name: "Sıfırlama bağlantısı gönder" }).click();
    await expect(page.getByText("Bağlantı gönderildi")).toBeVisible();
  });
});
