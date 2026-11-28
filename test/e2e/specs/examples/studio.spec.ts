import { test, expect, type Page } from '@playwright/test';
import { withExternalDb } from '../../helpers/env';

const studios = [
  { name: 'SQLite (client)', path: '/examples/sqlite/client', quote: '"', missing: 'no such column: age' },
  { name: 'SQLite (server)', path: '/examples/sqlite/server', quote: '"', missing: 'no such column: age' },
  { name: 'Postgres', path: '/examples/postgres', quote: '"', missing: 'column "age" does not exist', external: true },
  { name: 'MySQL', path: '/examples/mysql', quote: '`', missing: "Unknown column 'age' in 'field list'", external: true },
];

for (const studio of studios) {
  test.describe(`${studio.name} Studio`, () => {
    test.skip(!!studio.external && !withExternalDb, 'needs E2E_EXTERNAL_DB=1 and a database URL');

    const open = async (page: Page) => {
      await page.goto(studio.path);
      await expect(page.locator('.studio-table', { hasText: 'users' })).toBeVisible();
      // Wait for the island to hydrate before typing.
      await page.waitForFunction(() => !!(globalThis as any).__zx_web);
      return page.locator('.studio-code > textarea');
    };

    test('opens and filters tables', async ({ page }) => {
      const editor = await open(page);
      await page.locator('.studio-table', { hasText: 'users' }).click();
      await expect(editor).toHaveValue(`SELECT * FROM ${studio.quote}users${studio.quote} LIMIT 100;`);
      await expect(page.locator('.studio-grid th')).toHaveText(['id', 'name', 'email']);
      await expect(page.locator('.studio-grid td', { hasText: /^Ada$/ })).toBeVisible();
      await expect(page.locator('.studio-diagnostic')).toBeHidden();

      await page.locator('.studio-search').fill('zzz');
      await expect(page.locator('.studio-table', { hasText: 'users' })).toBeHidden();
    });

    test('highlights, completes and describes names', async ({ page }) => {
      const editor = await open(page);
      await editor.click();
      await page.keyboard.type('SELECT id, na');
      await expect(page.locator('.studio-suggest button.active')).toContainText('name');
      await page.keyboard.press('Enter');
      await page.keyboard.type(' FROM users');
      await expect(editor).toHaveValue('SELECT id, name FROM users');
      await expect(page.locator('.studio-highlight .tok-keyword').first()).toHaveText('SELECT');

      // The highlight layer sits under the textarea, so hover by position.
      const table = page.locator('.studio-highlight .tok-table');
      await expect(table).toHaveText('users');
      await expect(async () => {
        const box = (await table.boundingBox())!;
        await page.mouse.move(box.x + 1, box.y + 1);
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
        await expect(page.locator('.studio-hover')).toContainText('table users', { timeout: 1000 });
      }).toPass();
      await expect(page.locator('.studio-hover')).toContainText('email');
    });

    test('reports DB errors in place and runs each statement', async ({ page }) => {
      const editor = await open(page);
      await editor.fill('SELECT id FROM users;\nSELECT age FROM users;');
      await expect(page.locator('.studio-diagnostic')).toContainText(studio.missing);
      await expect(page.locator('.squiggle')).toHaveText(['age']);

      await editor.press('ControlOrMeta+Enter');
      await expect(page.locator('.studio-result-tabs button')).toHaveText(['Result 1', 'Result 2']);
      await expect(page.locator('.studio-result-tabs .failed')).toHaveText('Result 2');
      await expect(page.locator('.studio-result-error')).toContainText(studio.missing);
      await expect(page.locator('.studio-result-error')).toContainText('Ln 2, Col 8');
      await expect(page.locator('.studio-run')).toBeEnabled();

      await page.locator('.studio-result-tabs button', { hasText: 'Result 1' }).click();
      await expect(page.locator('.studio-grid th')).toHaveText(['id']);
    });

    test('keeps query tabs across reloads', async ({ page }) => {
      const editor = await open(page);
      await editor.fill('SELECT 1;');
      await page.getByRole('button', { name: 'New query' }).click();
      await editor.fill('SELECT 2 AS two;');
      const tabs = page.locator('.studio-tab > button:first-child');
      await expect(tabs).toHaveText(['Query 1', 'Query 2']);
      // Saving is queued before tokenizing, so these tokens mean the tabs are stored.
      await expect(page.locator('.studio-highlight .tok-keyword')).toHaveText(['SELECT', 'AS']);

      await page.reload();
      await expect(tabs).toHaveText(['Query 1', 'Query 2']);
      await expect(editor).toHaveValue('SELECT 2 AS two;');
      await page.locator('.studio-tab > button', { hasText: 'Query 1' }).click();
      await expect(editor).toHaveValue('SELECT 1;');
    });
  });
}
