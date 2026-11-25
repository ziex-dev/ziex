import { test, expect, type Page } from '@playwright/test';

// Typed browser bindings (`zx.client.web`) driven from Zig.
test.describe('Browser APIs Example', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/examples/web');
    await expect(page.getByRole('heading', { name: 'Browser APIs' })).toBeVisible();
  });

  async function pixel(page: Page, x: number, y: number) {
    return page.evaluate(([px, py]) => {
      const canvas = document.getElementById('web-canvas') as HTMLCanvasElement;
      return Array.from(canvas.getContext('2d')!.getImageData(px!, py!, 1, 1).data);
    }, [x, y]);
  }

  test('draws on a canvas', async ({ page }) => {
    expect(await pixel(page, 50, 50)).toEqual([0, 0, 0, 0]);
    await page.locator('#web-draw').click();
    await expect.poll(() => pixel(page, 50, 50)).toEqual([255, 0, 0, 255]);
    expect(await pixel(page, 150, 50)).toEqual([0, 0, 255, 255]);
  });

  test('drag and drop reads the DataTransfer', async ({ page }) => {
    await page.locator('#web-item-a').dragTo(page.locator('#web-item-b'));
    await expect(page.locator('#web-dropped')).toHaveText('Dropped web-item-a on web-item-b');
  });

  test('requestAnimationFrame calls back into Zig', async ({ page }) => {
    await page.locator('#web-frames').click();
    await expect(page.locator('#web-frame-count')).toHaveText('10 frames');
  });

  test('non-bubbling mouseenter reaches its handler', async ({ page }) => {
    await page.locator('#web-hover').hover();
    await expect(page.locator('#web-hovered')).toHaveText('Entered');
  });

  test('ships only the bindings the app imports', async ({ page }) => {
    const glue = await page.evaluate(() => {
      const shims = (globalThis as any).__zx_web;
      return typeof shims === 'function' ? shims.toString().length : 0;
    });
    expect(glue).toBeGreaterThan(0);
    // The full table is ~190 KB; one app should need a small slice of it.
    expect(glue).toBeLessThan(40_000);
  });
});
