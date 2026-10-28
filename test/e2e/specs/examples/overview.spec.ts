import { test, expect } from '@playwright/test';

test.describe('Examples Overview', () => {
  test('index page shows the categorized example directory', async ({ page }) => {
    await page.goto('/examples');

    await expect(page.getByRole('heading', { level: 1, name: 'Examples' })).toBeVisible();
    const directory = page.locator('.examples-directory');
    await expect(directory.getByRole('heading', { name: 'Rendering' })).toBeVisible();
    await expect(directory.getByRole('heading', { name: 'Data & APIs' })).toBeVisible();
    await expect(directory.getByRole('heading', { name: 'Forms & Actions' })).toBeVisible();
    await expect(page.getByRole('link', { name: /Counter.*zx\.State/ })).toBeVisible();
    await expect(page.getByRole('link', { name: /Database.*zx\.db/ })).toBeVisible();
  });

  test('sidebar links navigate to example applications', async ({ page }) => {
    await page.goto('/examples');

    await page.getByRole('link', { name: 'Counter', exact: true }).click();
    await expect(page).toHaveURL(/\/examples\/counter/);

    await page.goto('/examples');
    await page.getByRole('link', { name: 'Todo', exact: true }).click();
    await expect(page).toHaveURL(/\/examples\/todo$/);

    await page.goto('/examples');
    await page.getByRole('link', { name: 'Auth Form', exact: true }).click();
    await expect(page).toHaveURL(/\/examples\/auth/);
  });

  test('overview page renders QuickExample content', async ({ page }) => {
    await page.goto('/examples/overview');
    await expect(page.getByText(/Hello,\s*Ziex\s*Dev!/i)).toBeVisible({ timeout: 15_000 });
    await expect(page.getByText('John')).toBeVisible();
    await expect(page.getByText('Jane')).toBeVisible();
  });
});
