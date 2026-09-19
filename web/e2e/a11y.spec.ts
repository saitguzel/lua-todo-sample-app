import { test, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";
import { wait_for_app, login } from "./helpers";

const pages: Array<{ name: string; hash: string }> = [
  { name: "login", hash: "#/login" },
  { name: "dashboard", hash: "#/" },
  { name: "todos", hash: "#/todos" },
  { name: "profile", hash: "#/profile" },
];

for (const theme of ["light", "dark"]) {
  test.describe(`a11y (${theme})`, () => {
    test.use({ colorScheme: theme === "dark" ? "dark" : "light" });

    for (const p of pages) {
      test(`${p.name}: 0 serious/critical ihlal`, async ({ page }) => {
        if (p.hash !== "#/login") {
          await login(page, "user@todoapp.local", "User123!");
        }
        await page.goto(p.hash);
        await wait_for_app(page);
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
