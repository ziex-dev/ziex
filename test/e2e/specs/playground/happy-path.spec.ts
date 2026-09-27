// spec: playground test plan
import { test, expect } from '@playwright/test';
import { skipOnRemoteStatic } from '../../helpers/env';


test.describe('Ziex Playground', () => {
  test.describe.configure({ timeout: 180_000 });
  test('Page Load & Initial State', async ({ page }) => {
    await page.goto('/playground');
    await expect(page.getByRole('button', { name: 'Run' })).toBeVisible();
    if (!skipOnRemoteStatic) {
      await expect(page.getByRole('button', { name: 'Format file' })).toBeVisible();
      await expect(page.getByText('Console')).toBeVisible();
    }
    await expect(page.getByRole('button', { name: /Share/ })).toBeVisible();
    await expect(page.getByRole('button', { name: /Playground\.zx/ })).toBeVisible();
    await expect(page.getByRole('button', { name: /style\.css/ })).toBeVisible();
    const runButton = page.getByRole('button', { name: 'Run' });
    await runButton.waitFor({ state: 'visible' });
    await page.waitForFunction(() => {
      const btn = Array.from(document.querySelectorAll('button')).find(b => b.textContent?.trim() === 'Run');
      return btn && !btn.disabled;
    });
    await runButton.click();
    await page.waitForTimeout(2000);
    const previewFrame = page.frameLocator('iframe');
    await expect(previewFrame.getByRole('heading', { name: /Ziex Playground/ })).toBeVisible({ timeout: 120_000 });
  });

  test('Edit Code and Run', async ({ page }) => {
    await page.goto('/playground');
    const editor = page.getByRole('textbox').first();
    await editor.click();
    await editor.type('\n// test comment');
    const runButton = page.getByRole('button', { name: 'Run' });
    await runButton.waitFor({ state: 'visible' });
    await page.waitForFunction(() => {
      const btn = Array.from(document.querySelectorAll('button')).find(b => b.textContent?.trim() === 'Run');
      return btn && !btn.disabled;
    });
    await runButton.click();
    await page.waitForTimeout(2000);
    const previewFrame = page.frameLocator('iframe');
    await expect(previewFrame.getByRole('heading', { name: /Ziex Playground/ })).toBeVisible({ timeout: 120_000 });
  });

  test('Add New File', async ({ page }) => {
    await page.goto('/playground');
    // Static HTML includes the add-file button before editor.js attaches its handler.
    // Wait until Run is enabled so the module init (and addFile listener) has finished.
    await expect(page.getByRole('button', { name: 'Run' })).toBeEnabled({ timeout: 60_000 });
    // Handler must be registered before click; prompt() blocks click until accept/dismiss.
    page.once('dialog', dialog => {
      void dialog.accept('test.zx');
    });
    await page.getByRole('button', { name: /Add new file/ }).click();
    await expect(page.getByRole('button', { name: /test\.zx/ })).toBeVisible();
  });

  test('Switch Between Files', async ({ page }) => {
    await page.goto(`/playground`);
    await page.getByRole('button', { name: /style\.css/ }).click();
    await expect(page.getByRole('button', { name: /style\.css/ })).toBeVisible();
    await page.getByRole('button', { name: /Playground\.zx/ }).click();
    await expect(page.getByRole('button', { name: /Playground\.zx/ })).toBeVisible();
  });

  test('Close File Tab', async ({ page }) => {
    await page.goto(`/playground`);
    const closeBtn = page.getByRole('button', { name: 'style.css Close tab' });
    await closeBtn.click();
  });

  test('Share Button', async ({ page }) => {
    await page.goto(`/playground`);
    const shareButton = page.getByRole('button', { name: /Share/ });
    await shareButton.waitFor({ state: 'visible' });
    await page.waitForFunction(() => {
      const btn = Array.from(document.querySelectorAll('button')).find(b => b.textContent?.trim().includes('Share'));
      return btn && !btn.disabled;
    });
    await shareButton.click();
  });

  test('Format Button', async ({ page }) => {
    test.skip(skipOnRemoteStatic, 'Format status-bar control may not be on static deploy yet');
    await page.goto('/playground');
    const formatButton = page.getByRole('button', { name: 'Format file' });
    await formatButton.waitFor({ state: 'visible' });
    await page.waitForFunction(() => {
      const btn = document.getElementById('pg-format-btn') as HTMLButtonElement | null;
      return btn && !btn.disabled;
    });
    await formatButton.click();
    await expect(page.getByText(/Formatted .*Playground\.zx/)).toBeVisible({ timeout: 120_000 });
  });

  test('Console Panel', async ({ page }) => {
    test.skip(skipOnRemoteStatic, 'Console panel controls may not match static deploy UI yet');
    await page.goto(`/playground`);
    await page.getByRole('button', { name: /Toggle console/ }).click();
    await page.getByRole('button', { name: /Clear console/ }).click();
  });

  test('Error Handling', async ({ page }) => {
    await page.goto(`/playground`);
    const editor = page.getByRole('textbox').first();
    await editor.click();
    await editor.type('\nthis is invalid code');
    const runButton = page.getByRole('button', { name: 'Run' });
    await runButton.waitFor({ state: 'visible' });
    await page.waitForFunction(() => {
      const btn = Array.from(document.querySelectorAll('button')).find(b => b.textContent?.trim() === 'Run');
      return btn && !btn.disabled;
    });
    await runButton.click();
    await expect(page.getByText(/error|invalid|failed/i)).toBeVisible({ timeout: 120_000 });
  });

  test('Keyboard Navigation', async ({ page }) => {
    await page.goto(`/playground`);
    await page.keyboard.press('Tab');
    await page.keyboard.press('Tab');
    await page.keyboard.press('Tab');
  });

  test('File Persistence (should reset to initial template)', async ({ page }) => {
    await page.goto(`/playground`);
    const editor = page.getByRole('textbox').first();
    await editor.click();
    await editor.type('\n// persist test');
    await page.reload();
    const runButton = page.getByRole('button', { name: 'Run' });
    await runButton.waitFor({ state: 'visible' });
    await page.waitForFunction(() => {
      const btn = Array.from(document.querySelectorAll('button')).find(b => b.textContent?.trim() === 'Run');
      return btn && !btn.disabled;
    });
    await runButton.click();
    await page.waitForTimeout(2000);
    const previewFrame = page.frameLocator('iframe');
    await expect(previewFrame.getByRole('heading', { name: /Ziex Playground/ })).toBeVisible({ timeout: 120_000 });
  });
});
