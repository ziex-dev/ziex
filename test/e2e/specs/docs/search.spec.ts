import { test, expect } from '@playwright/test';

// Docs search is a ziex client component (components/docs_search.zx).
test.describe('Docs search', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/learn');
    // Wait for the island to hydrate before typing.
    await page.waitForFunction(() => !!(globalThis as any).__zx_web);
  });

  test('shows ranked results as you type', async ({ page }) => {
    const input = page.locator('#docs-search');
    await input.fill('install');
    const options = page.locator('#docs-search-results [role="option"]');
    await expect(options.first()).toBeVisible();
    expect(await options.count()).toBeLessThanOrEqual(8);
    await expect(options.first().locator('.top-bar-search-result-title')).toContainText(/install/i);
    await expect(input).toHaveAttribute('aria-expanded', 'true');
  });

  test('says when nothing matches', async ({ page }) => {
    await page.locator('#docs-search').fill('zzqqxx');
    await expect(page.locator('.top-bar-search-empty')).toHaveText('No results');
  });

  test('arrow keys move the selection and Enter navigates', async ({ page }) => {
    const input = page.locator('#docs-search');
    await input.fill('state');
    const options = page.locator('#docs-search-results [role="option"]');
    await expect(options.nth(1)).toBeVisible();
    await expect(options.nth(0)).toHaveAttribute('aria-selected', 'true');
    await input.press('ArrowDown');
    await expect(options.nth(1)).toHaveAttribute('aria-selected', 'true');
    await input.press('ArrowUp');
    await expect(options.nth(0)).toHaveAttribute('aria-selected', 'true');

    const href = await options.nth(0).locator('a').getAttribute('href');
    await input.press('Enter');
    await expect(page).toHaveURL(new RegExp(href!.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$'));
  });

  test('Escape closes; clicking outside closes', async ({ page }) => {
    const input = page.locator('#docs-search');
    const list = page.locator('#docs-search-results');
    await input.fill('route');
    await expect(list).toBeVisible();
    await input.press('Escape');
    await expect(list).toBeHidden();
    await expect(input).not.toBeFocused();

    await input.focus();
    await expect(list).toBeVisible();
    await page.locator('main').first().click({ position: { x: 5, y: 5 } });
    await expect(list).toBeHidden();
  });

  test('"/" and Cmd/Ctrl+K focus the search box', async ({ page }) => {
    const input = page.locator('#docs-search');
    await page.locator('body').press('/');
    await expect(input).toBeFocused();
    await input.blur();
    await page.keyboard.press('ControlOrMeta+k');
    await expect(input).toBeFocused();
  });

  test('clicking a result navigates', async ({ page }) => {
    await page.locator('#docs-search').fill('caching');
    const link = page.locator('#docs-search-results a').first();
    const href = (await link.getAttribute('href'))!;
    await link.click();
    await expect(page).toHaveURL(new RegExp(href.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$'));
  });
});
