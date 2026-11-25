import { test, expect } from '@playwright/test';

test.describe('Worker Example', () => {
  test('adding a note runs SQLite in a Web Worker', async ({ page }) => {
    await page.goto('/examples/worker');
    const total = page.getByText(/Notes stored:\s*\d+/);
    await expect(total).toBeVisible();

    const read = async () => Number((await total.innerText()).replace(/\D/g, ''));
    await page.getByRole('button', { name: 'Add note' }).click();
    // Persists in OPFS, so the count keeps growing across runs.
    await expect.poll(read).toBeGreaterThan(0);
    const first = await read();

    await page.getByRole('button', { name: 'Add note' }).click();
    await expect.poll(read).toBe(first + 1);
  });
});
