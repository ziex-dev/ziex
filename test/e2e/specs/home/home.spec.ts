import { test, expect, type Page } from '@playwright/test';
import {
  createDocsSnippetFilesFromEntries,
  isPlaygroundOpenable,
  decodeFilesFromQuery,
  type SnippetEntry,
} from '../../../../site/app/scripts/playground_share';

// The home page's behaviour is Zig (site/app/pages/home/*.zig via zx.client.web);
// it ships no page JavaScript of its own.

function collectErrors(page: Page) {
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(m.text());
  });
  return errors;
}

async function canvasHash(page: Page, feature: string) {
  return page.evaluate((id) => {
    const c = document.querySelector(`canvas.feature-canvas[data-feature="${id}"]`) as HTMLCanvasElement;
    const data = c.getContext('2d')!.getImageData(0, 0, c.width, c.height).data;
    let h = 0, lit = 0;
    for (let i = 0; i < data.length; i += 4) {
      h = (h * 31 + data[i]! + data[i + 1]! * 7 + data[i + 2]! * 13) | 0;
      if (data[i + 3]! > 0) lit++;
    }
    return { h, lit };
  }, feature);
}

test.describe('Home page (Zig)', () => {
  test('loads no page script besides the ziex runtime', async ({ page }) => {
    const errors = collectErrors(page);
    await page.goto('/');
    await page.waitForLoadState('networkidle');
    // Same-origin only: release builds also load analytics (GTM / Clarity).
    const scripts = await page.$$eval('script[src]', (els) =>
      els.map((e) => (e as HTMLScriptElement).src).filter((s) => new URL(s).origin === location.origin),
    );
    const page_scripts = scripts.filter((s) => !/\/assets\/(_\/)?app[.\w]*\.js|devscript\.js/.test(s));
    expect(page_scripts).toEqual([]);
    expect(errors).toEqual([]);
  });

  test('feature canvases draw and animate', async ({ page }) => {
    await page.goto('/');
    const ids = await page.$$eval('canvas.feature-canvas', (els) => els.map((e) => e.getAttribute('data-feature')!));
    expect(ids.length).toBeGreaterThanOrEqual(8);
    for (const id of ids) {
      const canvas = page.locator(`canvas.feature-canvas[data-feature="${id}"]`);
      await canvas.scrollIntoViewIfNeeded();
      await expect.poll(async () => (await canvasHash(page, id)).lit).toBeGreaterThan(1000);
      const first = await canvasHash(page, id);
      await expect.poll(async () => (await canvasHash(page, id)).h, { timeout: 5000 }).not.toBe(first.h);
    }
  });

  // Home code blocks sit in sections that opt out of copy buttons; the install box has one.
  test('install box copy button copies the command', async ({ page, context, browserName }) => {
    test.skip(browserName !== 'chromium', 'clipboard permissions are chromium-only');
    await context.grantPermissions(['clipboard-read', 'clipboard-write']);
    await page.goto('/');
    const button = page.locator('.install-box .copy-button').first();
    await expect(button).toBeAttached();
    // Reference: the command text exactly as clipboard.js built it.
    const code = await button.evaluate((b) => {
      const box = b.closest('.install-box')!;
      let install: Element | null = null;
      const checked = box.querySelector<HTMLInputElement>('.install-tab-radio:checked');
      if (checked) install = box.querySelector('#content-' + checked.id.replace('tab-', ''))?.querySelector('.install-code') ?? null;
      install ??= box.querySelector('.install-code');
      const lines = install!.querySelectorAll('.install-code-multiline > div');
      return lines.length > 0
        ? Array.from(lines).map((l) => l.textContent!.replace(/^\$\s*|^>\s*/, '').trim()).join(' && ')
        : install!.textContent!.replace(/^\$\s*|^>\s*/, '').replace(' #or', '').trim();
    });
    expect(code.length).toBeGreaterThan(0);
    await button.click({ force: true });
    await expect(button).toHaveClass(/copied/);
    expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(code);
    await expect(button).not.toHaveClass(/copied/, { timeout: 4000 });
  });

  test('playground links match the original TypeScript packing', async ({ page }) => {
    await page.goto('/');
    const containers = page.locator('.code-example, .code-preview-example').filter({ has: page.locator('.code-example-open-playground') });
    const n = await containers.count();
    expect(n).toBeGreaterThan(5);

    for (let i = 0; i < n; i++) {
      const container = containers.nth(i);
      // Reference: entries exactly as the removed home.ts collected them.
      const entries = await container.evaluate(collectHomeSnippetEntries);
      const expected = createDocsSnippetFilesFromEntries(entries.filter((e) => isPlaygroundOpenable(e.filename, e.code)));

      const [popup] = await Promise.all([
        page.waitForEvent('popup'),
        container.locator('.code-example-open-playground').click({ force: true }),
      ]);
      const url = new URL(popup.url());
      await popup.close();
      expect(url.pathname).toBe('/playground');
      const files = await decodeFilesFromQuery(url.hash.replace(/^#data=/, ''));
      expect(files, `container ${i}`).toEqual(expected);
    }
  });

  test('feature nav scrolls to a feature and highlights it', async ({ page }) => {
    await page.goto('/');
    const buttons = page.locator('.features-nav-btn');
    const last = buttons.last();
    const target = await last.getAttribute('data-feature-target');
    await last.click();
    await expect(page.locator(`#${target}`)).toBeInViewport();
    await expect(page.locator('.features-nav-item.is-active .features-nav-btn')).toHaveAttribute('data-feature-target', target!);
  });

  test('runners dash across sections and react to clicks', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('.section-runner').first()).toBeAttached();
    // Section runners come first in the DOM; the footer runner gets the first persona.
    const wrap = page.locator('footer .footer-runner-wrap');
    await wrap.scrollIntoViewIfNeeded();
    const transform = () => wrap.evaluate((el) => (el as HTMLElement).style.transform);
    const before = await transform();
    await expect.poll(transform).not.toBe(before);

    const bubble = wrap.locator('.footer-runner-bubble');
    await expect(bubble).toHaveText('catch me!');
    await wrap.locator('.footer-runner-mascot').click({ force: true });
    await expect(bubble).toHaveText('oops!');
    await expect(wrap).toHaveClass(/is-paused/);
  });

  test('Ziggy patrols the code windows', async ({ page }) => {
    await page.goto('/');
    const target = page.locator('#control-flow-tabs');
    await target.scrollIntoViewIfNeeded();
    const layers = page.locator('.ziggy-crawler');
    await expect.poll(() => layers.count()).toBeGreaterThanOrEqual(4);
    const back = target.locator('xpath=..').locator('.ziggy-crawler--back');
    const transform = () => back.evaluate((el) => (el as HTMLElement).style.transform);
    await expect.poll(transform).toContain('translate(');
    const before = await transform();
    await expect.poll(transform, { timeout: 6000 }).not.toBe(before);
    await expect(back.locator('svg')).toHaveAttribute('class', /ziggy/);
  });
});

/** Verbatim snippet collection from the removed site/app/scripts/home.ts. */
function collectHomeSnippetEntries(container: Element): SnippetEntry[] {
  const filenameFromSection = (section: string | undefined, fallback: string): string => {
    if (!section) return fallback;
    const lower = section.toLowerCase();
    if (lower.includes('layout')) return 'layout.zx';
    if (lower.includes('websocket')) return 'routes/ws/route.zig';
    if (lower.includes('api route') || /(^|:\s*)route\b/.test(lower)) return 'route.zig';
    if (lower.includes('dynamic path')) return 'pages/[id]/page.zx';
    if (lower.endsWith(': page') || lower.includes('routing: page')) return 'page.zx';
    if (lower.includes('client-side')) return 'page.zx';
    return fallback;
  };
  const filenameFromTitle = (title: string | null | undefined): string => {
    const raw = (title ?? '').trim();
    return raw || 'example.zx';
  };
  const extract = (panel: HTMLElement | null): string => panel?.querySelector('code')?.textContent?.trim() || '';
  const title = container.querySelector('.code-example-title')?.textContent?.trim() ?? '';

  if (container.classList.contains('code-example--tabs')) {
    const panels = Array.from(container.querySelectorAll<HTMLElement>('.code-example-panel'));
    const labels = Array.from(container.querySelectorAll<HTMLLabelElement>('.code-example-tab-label'));
    const radios = Array.from(container.querySelectorAll<HTMLInputElement>('.code-example-tab-radio'));
    const entries: SnippetEntry[] = [];
    for (let i = 0; i < panels.length; i++) {
      const code = extract(panels[i]!);
      if (!code) continue;
      const label = labels[i]?.textContent?.trim() ?? 'example';
      entries.push({ code, filename: filenameFromSection(panels[i]!.dataset.section, `${label.toLowerCase().replace(/\s+/g, '-')}.zx`) });
    }
    if (entries.some((e) => e.filename === 'page.zx') && entries.some((e) => e.filename === 'layout.zx')) {
      return entries.filter((e) => e.filename === 'page.zx' || e.filename === 'layout.zx');
    }
    const checked = radios.findIndex((r) => r.checked);
    const visible = panels[checked >= 0 && checked < panels.length ? checked : 0]!;
    const code = extract(visible);
    if (!code) return [];
    const idx = panels.indexOf(visible);
    const label = labels[idx]?.textContent?.trim() ?? 'example';
    return [{ code, filename: filenameFromSection(visible.dataset.section, `${label.toLowerCase().replace(/\s+/g, '-')}.zx`) }];
  }

  if (container.classList.contains('code-preview-example')) {
    const panel =
      container.querySelector<HTMLElement>('.code-preview-code .code-example-panel') ||
      container.querySelector<HTMLElement>('pre code');
    const code = panel?.textContent?.trim() || '';
    if (!code) return [];
    return [{ code, filename: filenameFromTitle(title) || 'page.zx' }];
  }

  const code = container.querySelector('pre code')?.textContent?.trim() || '';
  if (!code) return [];
  return [{ code, filename: filenameFromTitle(title) }];
}
