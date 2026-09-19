import { test, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";
import { wait_for_app, login, create_user } from "./helpers";

const pages: Array<{ name: string; hash: string; admin?: boolean }> = [
  { name: "login", hash: "#/login" },
  { name: "dashboard", hash: "#/" },
  { name: "todos", hash: "#/todos" },
  { name: "todo formu", hash: "#/todos/new" },
  { name: "profile", hash: "#/profile" },
  { name: "users", hash: "#/users", admin: true },
  { name: "rbac", hash: "#/rbac", admin: true },
  { name: "audit", hash: "#/audit-logs", admin: true },
];

for (const theme of ["light", "dark"]) {
  test.describe(`a11y (${theme})`, () => {
    test.use({ colorScheme: theme === "dark" ? "dark" : "light" });

    for (const p of pages) {
      test(`${p.name}: 0 serious/critical ihlal`, async ({ page, request }) => {
        if (p.hash !== "#/login") {
          const u = await create_user(request, p.admin ? "admin" : "todouser");
          await login(page, u.email, u.password);
        }
        await page.goto(p.hash);
        await wait_for_app(page);
        await page.locator("[aria-busy='true']").first().waitFor({ state: "detached", timeout: 5000 }).catch(() => {});
        const results = await new AxeBuilder({ page })
          .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"])
          .analyze();
        const serious = results.violations.filter(
          (v) => v.impact === "serious" || v.impact === "critical");
        expect(serious).toEqual([]);
      });
    }
  });
}
