import { test, expect } from "@playwright/test";
import { wait_for_app, unique_email } from "./helpers";

// MailHog API (docker-compose'da 127.0.0.1:28025)
const MAILHOG = "http://127.0.0.1:28025";

test.describe("password reset", () => {
  test("forgot → MailHog linki → reset → yeni parola ile login", async ({ page, request }) => {
    test.skip(process.env.CI !== "true" && !(await request.get(MAILHOG + "/api/v2/messages").catch(() => null))?.ok(),
      "MailHog çalışmıyor");

    const email = unique_email("reset");
    // admin ile kullanıcı oluştur (setup) yerine seed user'ı kullan: user@todoapp.local
    await page.goto("#/forgot-password");
    await wait_for_app(page);
    await page.getByLabel("E-posta").fill("user@todoapp.local");
    await page.getByRole("button", { name: "Sıfırlama bağlantısı gönder" }).click();
    await expect(page.getByText("Bağlantı gönderildi")).toBeVisible();

    // MailHog'dan en son mesajı çek
    const messages = await (await request.get(`${MAILHOG}/api/v2/messages`)).json();
    const body = messages.items?.[0]?.Content?.Body ?? "";
    const match = body.match(/#\/reset-password\?token=([0-9a-f]{64})/);
    expect(match).toBeTruthy();

    // reset sayfası: token URL'den silinmeli (history.replaceState)
    await page.goto(`#/reset-password?token=${match![1]}`);
    await wait_for_app(page);
    await expect(page).not.toHaveURL(/token=/);
    await page.getByLabel("Yeni parola").fill("YeniParola2B");
    await page.getByLabel("Parolayı onayla").fill("YeniParola2B");
    await page.getByRole("button", { name: "Parolayı güncelle" }).click();
    await expect(page.getByText("Parolanız güncellendi")).toBeVisible();
  });

  test("kayıtsız e-posta aynı başarı mesajını alır", async ({ page }) => {
    await page.goto("#/forgot-password");
    await wait_for_app(page);
    await page.getByLabel("E-posta").fill(unique_email("ghost"));
    await page.getByRole("button", { name: "Sıfırlama bağlantısı gönder" }).click();
    await expect(page.getByText("Bağlantı gönderildi")).toBeVisible();
  });
});
