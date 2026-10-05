import { test, expect } from '@playwright/test';

if (process.env.TEMPLATE_TESTS) {
  test.describe('Template Home UI and Navigation', () => {
    test('Counter supports increment, decrement, and reset from any numeric state', async ({ page }) => {
      await page.goto('/');
      const counter = page.locator('main h5');
      const baseline = Number((await counter.textContent()) ?? 'NaN');
      expect(Number.isInteger(baseline)).toBeTruthy();

      await page.getByRole('button', { name: 'Increment' }).click();
      await expect(counter).toHaveText(String(baseline + 1));

      await page.getByRole('button', { name: 'Decrement' }).click();
      await page.getByRole('button', { name: 'Decrement' }).click();
      await expect(counter).toHaveText(String(baseline + 1 - 2));

      await page.getByRole('button', { name: 'Reset' }).click();
      await expect(counter).toHaveText('0');

      for (let i = 0; i < 12; i++) {
        await page.getByRole('button', { name: 'Decrement' }).click();
      }

      const negativeValue = Number((await counter.textContent()) ?? 'NaN');
      expect(negativeValue).toBeLessThan(0);
      await expect(page.getByRole('button', { name: 'Increment' })).toBeVisible();
    });
  });
}
