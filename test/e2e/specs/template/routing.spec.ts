import { test, expect } from '@playwright/test';

if (process.env.TEMPLATE_TESTS) {
  test.describe('Template Home UI and Navigation', () => {
    test('Internal routing between Home and example pages works', async ({ page }) => {
      await page.goto('/');

      await page.getByRole('link', { name: 'Client Action' }).click();
      await expect(page).toHaveURL(/\/actions\/client$/);
      await expect(page.getByRole('button', { name: /Click Me/ })).toBeVisible();

      await page.goto('/');
      await page.getByRole('link', { name: 'Server Event' }).click();
      await expect(page).toHaveURL(/\/actions\/server$/);
      await expect(page.getByRole('heading', { name: 'Ziex' })).toBeVisible();

      await page.goto('/');
      await expect(page.getByRole('button', { name: 'Reset' })).toBeVisible();
      await expect(page.getByRole('button', { name: 'Decrement' })).toBeVisible();
      await expect(page.getByRole('button', { name: 'Increment' })).toBeVisible();
    });
  });
}
