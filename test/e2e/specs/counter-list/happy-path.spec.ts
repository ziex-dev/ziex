import { test, expect } from '@playwright/test';

test.describe('Counter List Example', () => {
  test('every island rendered in a loop hydrates with its own state', async ({ page }) => {
    await page.goto('/examples/counter-list');

    const counters = page.locator('.example-test');
    await expect(counters).toHaveCount(3);

    await counters.nth(1).getByRole('button', { name: 'Increment' }).click();
    await counters.nth(2).getByRole('button', { name: 'Decrement' }).click();
    await counters.nth(2).getByRole('button', { name: 'Decrement' }).click();

    await expect(counters.nth(0).getByRole('heading')).toHaveText('Count: 0');
    await expect(counters.nth(1).getByRole('heading')).toHaveText('Count: 11');
    await expect(counters.nth(2).getByRole('heading')).toHaveText('Count: 18');

    await counters.nth(0).getByRole('button', { name: 'Increment' }).click();
    await expect(counters.nth(0).getByRole('heading')).toHaveText('Count: 1');
    await expect(counters.nth(1).getByRole('heading')).toHaveText('Count: 11');
  });
});
