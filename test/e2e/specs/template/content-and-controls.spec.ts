import { test, expect } from '@playwright/test';

if (process.env.TEMPLATE_TESTS) {
  test.describe('Template Home UI and Navigation', () => {
    test('Home page renders critical content and controls', async ({ page }) => {
      await page.goto('/');

      await expect(page).toHaveTitle('Ziex');
      await expect(page.getByRole('heading', { name: 'Ziex' })).toBeVisible();
      await expect(page.getByText('Ziex is a framework for building web applications with Zig.')).toBeVisible();

      const docsLink = page.getByRole('link', { name: 'See Ziex Docs →' });
      await expect(docsLink).toBeVisible();
      await expect(docsLink).toHaveAttribute('href', 'https://ziex.dev');

      await expect(page.getByRole('button', { name: 'Reset' })).toBeVisible();
      await expect(page.getByRole('button', { name: 'Decrement' })).toBeVisible();
      await expect(page.getByRole('button', { name: 'Increment' })).toBeVisible();

      const value = Number((await page.locator('main h5').textContent()) ?? 'NaN');
      expect(Number.isInteger(value)).toBeTruthy();

      await expect(page.getByRole('link', { name: 'Server State' })).toHaveAttribute('href', '/form');
      await expect(page.getByRole('link', { name: 'Server Action' })).toHaveAttribute('href', '/actions');
      await expect(page.getByRole('link', { name: 'Client Action' })).toHaveAttribute('href', '/actions/client');
      await expect(page.getByRole('link', { name: 'Server Event' })).toHaveAttribute('href', '/actions/server');
    });
  });
}
