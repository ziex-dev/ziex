import { test, expect } from '@playwright/test';
import {
  createDocsSnippetFilesFromEntries,
  isPlaygroundOpenable,
  decodeFilesFromQuery,
  type SnippetEntry,
} from '../../helpers/playground_share';

// Docs behaviour formerly in scripts/docs.ts, now server-rendered or Zig.
test.describe('Docs pages', () => {
  test('load no page script besides the ziex runtime', async ({ page }) => {
    await page.goto('/learn');
    const scripts = await page.$$eval('script[src]', (els) =>
      els.map((e) => (e as HTMLScriptElement).src).filter((s) => new URL(s).origin === location.origin),
    );
    expect(scripts.filter((s) => !/\/assets\/(_\/)?app[.\w]*\.js|devscript\.js/.test(s))).toEqual([]);
  });

  test('section headings link to themselves', async ({ page }) => {
    await page.goto('/reference');
    const anchors = page.locator('.section h2 .section-anchor, .section h3 .section-anchor');
    expect(await anchors.count()).toBeGreaterThan(40);
    const anchor = page.locator('h3#expr-strings .section-anchor');
    await expect(anchor).toHaveAttribute('href', '#expr-strings');
    await expect(anchor.locator('svg.section-anchor-icon')).toBeAttached();
    await expect(page.locator('#expressions h2 .section-anchor')).toHaveAttribute('href', '#expressions');
  });

  test('clicking a heading anchor copies its link', async ({ page, context, browserName }) => {
    test.skip(browserName !== 'chromium', 'clipboard permissions are chromium-only');
    await context.grantPermissions(['clipboard-read', 'clipboard-write']);
    await page.goto('/reference');
    await page.waitForFunction(() => !!(globalThis as any).__zx_web);
    await page.locator('h3#expr-strings .section-anchor').click();
    await expect(page).toHaveURL(/#expr-strings$/);
    await expect.poll(() => page.evaluate(() => navigator.clipboard.readText())).toMatch(/\/reference#expr-strings$/);
  });

  test('sidebar highlights the section in view', async ({ page }) => {
    await page.goto('/reference');
    await page.waitForFunction(() => !!(globalThis as any).__zx_web);
    // The active section is the last one whose top passed 120px from the top.
    await page.evaluate(() => scrollTo(0, document.getElementById('control-flow')!.getBoundingClientRect().top + scrollY - 60));
    await expect(page.locator('.sidebar a.active[href*="#control-flow"], .right-sidebar a.active[href*="#control-flow"]').first()).toBeAttached();
  });

  test('rendered HTML output is pre-formatted on the server', async ({ page }) => {
    await page.goto('/reference');
    const code = page.locator('code.language-markup').first();
    await expect(code.locator('span.tag').first()).toBeAttached();
    expect(await code.textContent()).toContain('\n');
  });

  test('sandbox playground links match the original docs.ts packing', async ({ page }) => {
    await page.goto('/reference');
    const sandboxes = page.locator('.sandbox').filter({ has: page.locator('a.sandbox-open-playground-btn') });
    const n = await sandboxes.count();
    expect(n).toBeGreaterThan(5);
    for (let i = 0; i < n; i++) {
      const sandbox = sandboxes.nth(i);
      const entries = await sandbox.evaluate(getSandboxSnippetEntries);
      const expected = createDocsSnippetFilesFromEntries(entries.filter((e) => isPlaygroundOpenable(e.filename, e.code)));
      const href = (await sandbox.locator('a.sandbox-open-playground-btn').getAttribute('href'))!;
      expect(href).toMatch(/^\/playground#data=/);
      expect(await decodeFilesFromQuery(href.split('#data=')[1]!), `sandbox ${i}`).toEqual(expected);
    }
  });
});

test.describe('Install tabs follow the visitor OS', () => {
  test.describe('Windows', () => {
    test.use({ userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0 Safari/537.36' });
    test('preselects Windows', async ({ page }) => {
      await page.goto('/learn');
      await expect(page.locator('#tab-windows')).toBeChecked();
      await expect(page.locator('#tab-zig-win')).toBeChecked();
    });
  });
  test.describe('Linux', () => {
    test.use({ userAgent: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/131.0 Safari/537.36' });
    test('preselects Linux / other', async ({ page }) => {
      await page.goto('/learn');
      await expect(page.locator('#tab-unix')).toBeChecked();
      await expect(page.locator('#tab-zig-other')).toBeChecked();
    });
  });
});

/** Verbatim from the removed scripts/docs.ts. */
function getSandboxSnippetEntries(sandbox: Element): SnippetEntry[] {
  const normalizeFileName = (raw: string | null): string => {
    if (!raw) return 'Playground.zx';
    const compact = raw.replace(/\s+/g, ' ').trim();
    return compact || 'Playground.zx';
  };
  const radios = Array.from(sandbox.querySelectorAll<HTMLInputElement>('.file-radio'));
  if (radios.length > 0) {
    const codeBlocks = Array.from(sandbox.querySelectorAll<HTMLElement>('.sandbox-editor .file-content code'));
    const labels = Array.from(sandbox.querySelectorAll<HTMLLabelElement>('.sandbox-file-tabs .sandbox-tab'));
    const entries: SnippetEntry[] = [];
    for (let i = 0; i < radios.length; i++) {
      const code = codeBlocks[i]?.textContent?.trim() ?? '';
      const filename = normalizeFileName(labels[i]?.textContent ?? null);
      if (code) entries.push({ code, filename });
    }
    return entries;
  }
  const codeNode = sandbox.querySelector<HTMLElement>('.sandbox-code code');
  const code = codeNode?.textContent?.trim() ?? '';
  if (!code) return [];
  const filenameNode = sandbox.querySelector<HTMLElement>('.sandbox-editor-header .sandbox-tab');
  return [{ code, filename: normalizeFileName(filenameNode?.textContent ?? null) }];
}
