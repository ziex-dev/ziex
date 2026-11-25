import { test, expect } from '@playwright/test';

test.describe('SQLite Studio Example', () => {
  test('runs queries in a Web Worker', async ({ page }) => {
    await page.goto('/examples/sqlite');
    const input = page.locator('#sqlite-input');

    // Tables load on mount; clicking one queries it.
    await page.locator('.studio-table', { hasText: 'users' }).click();
    await expect(input).toHaveValue('SELECT * FROM "users" LIMIT 100;');
    await expect(page.locator('.studio-grid th')).toHaveText(['id', 'name', 'email']);
    await expect(page.locator('.studio-grid td').nth(1)).toHaveText('Ada');

    await page.locator('.studio-search').fill('zzz');
    await expect(page.locator('.studio-table', { hasText: 'users' })).toBeHidden();
    await page.locator('.studio-search').fill('');

    await input.fill('SELECT 1 AS a,\n  2 AS b');
    await expect(page.getByText(/Ln 2 Col \d+/)).toBeVisible();
    await input.press('ControlOrMeta+Enter');
    await expect(page.locator('.studio-grid th')).toHaveText(['a', 'b']);

    await input.fill('SELECT * FROM missing_table');
    await page.getByRole('button', { name: 'Run' }).click();
    await expect(page.locator('.studio-error')).toContainText('Error:');
  });
});
