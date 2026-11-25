import { test, expect } from '@playwright/test';

/**
 * Call overhead of browser bindings: generated `zx.client.web` (one shim per
 * method) vs dynamic `zx.client.js` vs plain JS, 100k calls each.
 *
 *   npx playwright test specs/bench/web-perf.spec.ts --workers=1 --retries=0
 */
test.use({ video: 'off', screenshot: 'off', trace: 'off' });

const ROUNDS = Number(process.env.WEB_BENCH_ROUNDS ?? 3);

test('web bindings call overhead', async ({ page }) => {
  test.setTimeout(180_000);
  await page.goto('/bench/web');
  await expect(page.getByRole('heading', { name: 'Web bindings benchmark' })).toBeVisible();

  type Result = Record<'fillRect' | 'fillStyle' | 'setAttribute' | 'width', number[]>;
  const runs: Result[] = [];
  const plain: Record<string, number>[] = [];

  for (let r = 0; r < ROUNDS + 1; r++) {
    await page.evaluate(() => (document.getElementById('bench-result')!.textContent = ''));
    await page.locator('#bench-run').click();
    await expect(page.locator('#bench-result')).not.toHaveText('', { timeout: 60_000 });
    const res = JSON.parse((await page.locator('#bench-result').textContent())!);

    const js = await page.evaluate((n) => {
      const canvas = document.getElementById('bench-canvas') as HTMLCanvasElement;
      const el = document.getElementById('bench-el')!;
      const c = canvas.getContext('2d')!;
      let t = performance.now();
      for (let i = 0; i < n; i++) c.fillRect(i % 64, 0, 1, 1);
      const fillRect = performance.now() - t;
      t = performance.now();
      for (let i = 0; i < n; i++) c.fillStyle = i & 1 ? '#0000ff' : '#ff0000';
      const fillStyle = performance.now() - t;
      t = performance.now();
      for (let i = 0; i < n; i++) el.setAttribute('data-x', i & 1 ? 'b' : 'a');
      const setAttribute = performance.now() - t;
      let sum = 0;
      t = performance.now();
      for (let i = 0; i < n; i++) sum += canvas.width;
      const width = performance.now() - t;
      return { fillRect, fillStyle, setAttribute, width, sum };
    }, res.n);

    if (r === 0) continue; // warmup
    runs.push(res);
    plain.push(js);
  }

  const median = (xs: number[]) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)]!;
  const rows: Record<string, Record<string, string>> = {};
  for (const op of ['fillRect', 'fillStyle', 'setAttribute', 'width'] as const) {
    const direct = median(runs.map((x) => x[op][0]!));
    const dynamic = median(runs.map((x) => x[op][1]!));
    const js = median(plain.map((x) => x[op]!));
    rows[op] = {
      'plain JS ms': js.toFixed(1),
      'zx.client.web ms': direct.toFixed(1),
      'zx.client.js ms': dynamic.toFixed(1),
      'web / JS': (direct / js).toFixed(2) + 'x',
      'js / web': (dynamic / direct).toFixed(2) + 'x',
    };
  }
  console.log(`\nWeb bindings: ${runs[0]?.n ?? 0} calls per op, median of ${ROUNDS}`);
  console.table(rows);
});
