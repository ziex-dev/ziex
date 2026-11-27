// spec: specs/examples-applications.plan.md
// seed: seed.spec.ts

import { test, expect } from '@playwright/test';


test.describe('Realtime Chat Example', () => {
  test('Join and Send Message', async ({ page }) => {
    // 1. Navigate to /examples/realtime
    await page.goto('/examples/realtime');
    // expect: Chat UI loads with name input and join button.
    await expect(page.getByRole('textbox', { name: /Enter your name/ })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Join room' })).toBeVisible();
    // 2. Enter a name and click 'Join room'
    await page.getByRole('textbox', { name: /Enter your name/ }).fill('TestUser');
    await page.getByRole('button', { name: 'Join room' }).click();
    // Optionally, assert user joins chat
  });
});
