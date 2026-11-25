import { test, expect, chromium, type Page } from '@playwright/test';

// WebGPU from Zig (site/app/pages/examples/webgpu). The headless shell has no
// presentation surface, so rendering runs in full Chromium with WebGPU enabled.
test.describe('WebGPU Example', () => {
  test.describe('with WebGPU', () => {
    test('renders the embedded WGSL triangle every frame', async ({ browserName, baseURL }) => {
      test.skip(browserName !== 'chromium', 'WebGPU flag is chromium-only');
      const browser = await chromium.launch({ channel: 'chromium', args: ['--enable-unsafe-webgpu'] });
      test.info().attach('browser', { body: browser.version() });
      const page = await (await browser.newContext({ baseURL })).newPage();
      const warnings: string[] = [];
      page.on('console', (m) => {
        if (m.type() === 'warning' || m.type() === 'error') warnings.push(m.text());
      });
      await page.goto('/examples/webgpu');

      const status = page.locator('#webgpu-status');
      await expect(status).toContainText('Rendering with WebGPU', { timeout: 15_000 });
      const frame = async () => Number((await status.textContent())!.match(/frame (\d+)/)?.[1] ?? 0);
      const first = await frame();
      await expect.poll(frame).toBeGreaterThan(first);

      // CI runners have no GPU: frames run but never reach the screen, so pixels are local-only.
      if (!process.env.CI) await expectTriangleOnScreen(page);
      expect(warnings).toEqual([]);
      await browser.close();
    });
  });

  test('explains when WebGPU is unavailable', async ({ page, browserName }) => {
    test.skip(browserName !== 'chromium', 'availability differs per browser');
    await page.goto('/examples/webgpu');
    await expect(page.locator('#webgpu-status')).toHaveText(/not available/, { timeout: 15_000 });
  });
});

// Count pixels in the triangle's palette (green, cyan, amber) on screen.
async function expectTriangleOnScreen(page: Page): Promise<void> {
  const png = await page.locator('#webgpu-canvas').screenshot();
  const colored = await page.evaluate(async (b64) => {
    const blob = await (await fetch(`data:image/png;base64,${b64}`)).blob();
    const img = await createImageBitmap(blob);
    const c = new OffscreenCanvas(img.width, img.height);
    const g = c.getContext('2d')!;
    g.drawImage(img, 0, 0);
    const d = g.getImageData(0, 0, img.width, img.height).data;
    let n = 0;
    for (let i = 0; i < d.length; i += 4) if (d[i]! + d[i + 1]! + d[i + 2]! > 300) n++;
    return n;
  }, png.toString('base64'));
  expect(colored).toBeGreaterThan(2000);
}
