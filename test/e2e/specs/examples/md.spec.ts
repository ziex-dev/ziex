import { test, expect } from '@playwright/test';

test.describe('Markdown (MDZX) Example', () => {
  test('renders markdown, zx embed, props component, and page context path', async ({ page }) => {
    await page.goto('/examples/mdzx');

    await expect(page.getByRole('heading', { name: 'MDZX', exact: true })).toBeVisible({
      timeout: 15_000,
    });
    await expect(page.getByRole('heading', { name: 'H1 Header', exact: true })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Formatting' })).toBeVisible();
    await expect(page.getByText('/examples/md')).toBeVisible();
    await expect(page.getByText(/Hello,\s*Ziex\s*Dev!/i)).toBeVisible();
    // Greeting.mdzx props component (avoid loose "Ziex" which matches the brand link)
    await expect(page.getByRole('heading', { name: 'Hello' })).toBeVisible();
    await expect(page.getByText('greeting.mdzx')).toBeVisible();
    await expect(page.getByText('fenced code without trailing backticks')).toBeVisible();
    await expect(page.getByText('hello from Zig fence')).toBeVisible();
    await expect(page.getByText('type Point')).toBeVisible();
    await expect(page.getByText('```')).toHaveCount(0);
  });
});

test.describe('Pure Markdown Example', () => {
  test('renders page.md without ZX embeds', async ({ page }) => {
    await page.goto('/examples/md');

    await expect(page.getByRole('heading', { name: 'Pure Markdown', exact: true })).toBeVisible({
      timeout: 15_000,
    });
    await expect(page.getByText('documentation-only')).toBeVisible();
    await expect(page.getByText('const pure = true;')).toBeVisible();
    await expect(page.getByRole('link', { name: 'Back to MDZX example' })).toBeVisible();
  });
});
