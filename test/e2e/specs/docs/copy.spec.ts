import { test, expect } from '@playwright/test';

// Copy buttons on docs pages come from Zig (site/app/pages/components/copy.zig),
// not the old assets/clipboard.js.
test.describe('Docs copy buttons', () => {
  test('code blocks get a working copy button', async ({ page, context, browserName }) => {
    test.skip(browserName !== 'chromium', 'clipboard permissions are chromium-only');
    await context.grantPermissions(['clipboard-read', 'clipboard-write']);
    await page.goto('/learn');

    // Some blocks sit in inactive tabs; use one that is on screen.
    const pre = page.locator('pre:visible').filter({ has: page.locator('.copy-button') }).first();
    await pre.scrollIntoViewIfNeeded();
    await pre.hover();
    const button = pre.locator('.copy-button');
    const code = await pre.evaluate((p) => p.querySelector('code')!.textContent);
    await button.click();
    await expect(button).toHaveClass(/copied/);
    await expect(button).toHaveAttribute('aria-label', 'Copied!');
    expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(code);
    await expect(button).not.toHaveClass(/copied/, { timeout: 4000 });
  });

  test('each code block gets exactly one button', async ({ page }) => {
    await page.goto('/learn');
    await expect(page.locator('pre .copy-button').first()).toBeAttached();
    const counts = await page.$$eval('pre', (pres) => pres.map((p) => p.querySelectorAll(':scope > .copy-button').length));
    expect(Math.max(...counts)).toBe(1);
  });

  test('docs.js no longer ships the clipboard script', async ({ page }) => {
    const res = await page.request.get('/assets/docs.js');
    expect(res.ok()).toBeTruthy();
    expect(await res.text()).not.toContain('copyButtonHTML');
  });
});
