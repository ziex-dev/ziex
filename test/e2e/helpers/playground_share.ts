// Reference implementation of playground share links (the site renders them in
// Zig, see site/app/pages/home/share.zig); the specs check the two agree.

export type PlaygroundFilesMap = Record<string, string>;

export type SnippetEntry = {
    code: string;
    filename: string;
};

const ZX_IMPORT_LINE = 'const zx = @import("zx");';
const STD_IMPORT_LINE = 'const std = @import("std");';

const MINIMAL_LAYOUT = `pub fn Layout(ctx: zx.LayoutContext, children: zx.Component) zx.Component {
    return (
        <html @allocator={ctx.arena} lang="en-US">
            <head>
                <meta charset="UTF-8" />
                <title>Playground</title>
            </head>
            <body>
                {children}
            </body>
        </html>
    );
}

const zx = @import("zx");
`;

type ExampleLink = {
    href: string;
    label: string;
};

type UnsupportedFeatures = {
    caching: boolean;
    websocket: boolean;
    nonGetMethods: string[];
};

function ensureTopLevelZxImport(code: string): string {
    const hasTopLevelImport = code
        .split(/\r?\n/)
        .some((line) => /^const\s+zx\s*=\s*@import\("zx"\);\s*$/.test(line));

    if (hasTopLevelImport) {
        return code;
    }

    const normalized = code.replace(/\s+$/, "");
    return `${normalized}\n\n${ZX_IMPORT_LINE}`;
}

function ensureTopLevelStdImport(code: string): string {
    const usesStd = /std\.\w+/m.test(code);

    if (!usesStd) {
        return code;
    }

    const hasTopLevelImport = code
        .split(/\r?\n/)
        .some((line) => /^const\s+std\s*=\s*@import\("std"\);\s*$/.test(line));

    if (hasTopLevelImport) {
        return code;
    }

    const normalized = code.replace(/\s+$/, "");
    return `${normalized}\n\n${STD_IMPORT_LINE}`;
}

function processSnippetCode(code: string): string {
    let processedCode = code;
    processedCode = ensureTopLevelStdImport(processedCode);
    processedCode = ensureTopLevelZxImport(processedCode);
    return processedCode;
}

function basename(filename: string): string {
    const parts = filename.replace(/\\/g, "/").split("/");
    return parts[parts.length - 1] || filename;
}

function dirname(filename: string): string {
    const normalized = filename.replace(/\\/g, "/");
    const idx = normalized.lastIndexOf("/");
    return idx >= 0 ? normalized.slice(0, idx) : "";
}

function hasPageExport(code: string): boolean {
    return /\bpub\s+fn\s+Page\s*\(/.test(code);
}

function hasLayoutExport(code: string): boolean {
    return /\bpub\s+fn\s+Layout\s*\(/.test(code);
}

function looksLikeRoute(code: string, filename: string): boolean {
    const name = basename(filename).toLowerCase();
    if (name === "route.zig") return true;
    if (/\bzx\.RouteContext\b/.test(code)) return true;
    if (/\bzx\.SocketContext\b/.test(code) || /\bzx\.SocketOpenContext\b/.test(code)) return true;
    if (/\bpub\s+fn\s+(GET|POST|PUT|DELETE|PATCH|Socket|SocketOpen)\s*\(/.test(code) && /RouteContext|SocketContext|SocketOpenContext/.test(code)) {
        return true;
    }
    return false;
}

export function needsAppMode(code: string, filename = "Playground.zx"): boolean {
    const name = basename(filename).toLowerCase();
    if (looksLikeRoute(code, filename)) return true;
    if (name === "layout.zx" || name === "page.zx") return true;
    if (hasPageExport(code) || hasLayoutExport(code)) return true;
    if (/@client\b/.test(code)) return true;
    if (/\bzx\.client\./.test(code)) return true;
    if (/\bzx\.server\.Action\b/.test(code)) return true;
    if (/\bzx\.PageContext\b/.test(code)) return true;
    if (/\bzx\.LayoutContext\b/.test(code)) return true;
    if (/\[.+\]/.test(filename.replace(/\\/g, "/"))) return true;
    return false;
}

export function isPlaygroundOpenable(filename: string, code: string): boolean {
    const trimmed = code.trim();
    if (!trimmed) return false;

    const name = basename(filename).toLowerCase();
    if (
        name === "build.zig" ||
        name.endsWith(".json") ||
        name.endsWith(".sh") ||
        name.endsWith(".md") ||
        name.endsWith(".css") ||
        name.endsWith(".html")
    ) {
        return false;
    }

    if (name.endsWith(".zx") || name.endsWith(".zig")) return true;
    return needsAppMode(trimmed, filename) || /<[A-Za-z/!]/.test(trimmed);
}

function findPrimaryComponentName(code: string): string | null {
    const matches = code.matchAll(/\bpub\s+fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/g);
    for (const match of matches) {
        const name = match[1];
        if (!name || name === "Page" || name === "Layout") continue;
        if (/^(GET|POST|PUT|DELETE|PATCH|Socket|SocketOpen|main)$/.test(name)) continue;
        return name;
    }
    return null;
}

function componentTakesAllocator(code: string, name: string): boolean {
    const re = new RegExp(`\\bpub\\s+fn\\s+${name}\\s*\\(\\s*allocator\\s*:`);
    return re.test(code);
}

function wrapComponentAsPage(code: string): string {
    if (hasPageExport(code)) return code;

    const name = findPrimaryComponentName(code);
    if (!name) return code;

    const wantsClient =
        /@client\b/.test(code) ||
        /\bzx\.client\./.test(code) ||
        /\bzx\.client\.Action\b/.test(code);

    const allocatorAttr = componentTakesAllocator(code, name) ? " @allocator={ctx.arena}" : "";
    const renderingAttr = wantsClient ? " @client" : "";

    return `pub fn Page(ctx: zx.PageContext) !zx.Component {
    return (
        <main @allocator={ctx.arena}>
            <${name}${allocatorAttr}${renderingAttr} />
        </main>
    );
}

${code}`;
}

function stripAppPrefix(path: string): string {
    return path.startsWith("app/") ? path.slice(4) : path;
}

function firstRouteParam(code: string): string | null {
    const match = code.match(/params\.get\(\s*["'](\w+)["']\s*\)/);
    return match?.[1] ?? null;
}

function normalizeRouteAppPath(rawPath: string): string {
    let path = stripAppPrefix(rawPath.replace(/\\/g, "/").replace(/^\/+/, ""));

    // Playground serves API/WebSocket handlers from app/routes/...
    if (path.startsWith("pages/")) {
        path = `routes/${path.slice("pages/".length)}`;
    } else if (!path.startsWith("routes/")) {
        if (!path.includes("/") || path === "route.zig") {
            path = "routes/api/route.zig";
        } else {
            path = `routes/${path}`;
        }
    }

    if (!path.endsWith("/route.zig") && path !== "routes/route.zig") {
        const dir = dirname(path);
        path = dir ? `${dir}/route.zig` : "routes/api/route.zig";
    }

    return `app/${path}`;
}

function normalizePageAppPath(rawPath: string, code: string): string {
    let path = stripAppPrefix(rawPath.replace(/\\/g, "/").replace(/^\/+/, ""));
    if (path.startsWith("pages/")) {
        path = path.slice("pages/".length);
    }

    const name = basename(path).toLowerCase();

    if (!path.includes("/")) {
        const param = firstRouteParam(code);
        if (param) {
            return `app/pages/[${param}]/page.zx`;
        }
        return "app/pages/page.zx";
    }

    const dir = dirname(path);
    // Normalize any *.zx under a route folder to page.zx (e.g. user/[id]/user_profile.zx).
    if (name.endsWith(".zx")) {
        return `app/pages/${dir}/page.zx`;
    }
    return `app/pages/${path}`;
}

function mapEntryToAppPath(filename: string, code: string): string {
    const raw = filename.replace(/\\/g, "/").replace(/^\/+/, "");
    const name = basename(raw).toLowerCase();

    if (name === "layout.zx" || hasLayoutExport(code)) {
        let path = stripAppPrefix(raw);
        if (path.startsWith("pages/")) path = path.slice("pages/".length);
        if (!path.includes("/")) return "app/pages/layout.zx";
        return `app/pages/${dirname(path)}/layout.zx`;
    }

    if (looksLikeRoute(code, filename)) {
        return normalizeRouteAppPath(raw);
    }

    return normalizePageAppPath(raw, code);
}

function exampleValueForParam(param: string): string {
    const lower = param.toLowerCase();
    if (lower === "id" || lower.endsWith("_id") || lower.endsWith("id")) return "42";
    if (lower === "slug" || lower === "name") return "hello";
    return "example";
}

function urlFromAppPath(appPath: string): string | null {
    if (appPath === "app/pages/layout.zx" || appPath === "app/main.zig") return null;

    if (appPath.endsWith("/page.zx") || appPath === "app/pages/page.zx") {
        let route = appPath.slice("app/pages/".length).replace(/\/page\.zx$/, "");
        if (!route || route === "page.zx") return "/";
        return `/${route}`;
    }

    if (appPath.endsWith("/route.zig") || appPath.endsWith("route.zig")) {
        let route = appPath
            .replace(/^app\/routes\//, "")
            .replace(/^app\/pages\//, "")
            .replace(/\/route\.zig$/, "")
            .replace(/route\.zig$/, "");
        if (!route) return "/api";
        return `/${route}`;
    }

    return null;
}

function concreteExampleHref(urlPattern: string): string {
    return urlPattern.replace(/\[([^\]]+)\]/g, (_, param: string) => exampleValueForParam(param));
}

function collectExampleLinks(files: PlaygroundFilesMap): ExampleLink[] {
    const links: ExampleLink[] = [];
    const seen = new Set<string>();

    for (const path of Object.keys(files).sort()) {
        const pattern = urlFromAppPath(path);
        if (!pattern || pattern === "/") continue;
        const href = concreteExampleHref(pattern);
        if (seen.has(href)) continue;
        seen.add(href);
        links.push({ href, label: pattern });
    }

    return links;
}

function detectUnsupportedFeatures(files: PlaygroundFilesMap): UnsupportedFeatures {
    const allCode = Object.values(files).join("\n");
    const nonGetMethods: string[] = [];
    for (const method of ["POST", "PUT", "DELETE", "PATCH"] as const) {
        if (new RegExp(`\\bpub\\s+fn\\s+${method}\\s*\\(`).test(allCode)) {
            nonGetMethods.push(method);
        }
    }

    return {
        caching:
            /@caching\b/.test(allCode) ||
            /\.caching\s*=/.test(allCode) ||
            /\bzx\.cache\./.test(allCode) ||
            /\bPageOptions\b[\s\S]*caching/.test(allCode) ||
            /\bLayoutOptions\b[\s\S]*caching/.test(allCode),
        websocket:
            /\bpub\s+fn\s+Socket(Open)?\s*\(/.test(allCode) ||
            /\bzx\.SocketContext\b/.test(allCode) ||
            /\bzx\.SocketOpenContext\b/.test(allCode) ||
            /\.socket\.upgrade\b/.test(allCode) ||
            /\bzx\.WebSocket\b/.test(allCode),
        nonGetMethods,
    };
}

function escapeZigString(value: string): string {
    return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function buildSampleHomePage(files: PlaygroundFilesMap): string {
    const links = collectExampleLinks(files);
    const unsupported = detectUnsupportedFeatures(files);

    const linkItems = links
        .map((link) => `                <li><a href="${escapeZigString(link.href)}">${escapeZigString(link.label)}</a> → <code>${escapeZigString(link.href)}</code></li>`)
        .join("\n");

    const notices: string[] = [];
    if (unsupported.caching) {
        notices.push("Caching is not supported in the playground.");
    }
    if (unsupported.websocket) {
        notices.push("WebSockets are not supported in the playground.");
    }
    if (unsupported.nonGetMethods.length > 0) {
        notices.push(
            `${unsupported.nonGetMethods.join("/")} route handlers are not supported in the playground (GET only).`,
        );
    }

    const noticeBlock =
        notices.length > 0
            ? `
            <div>
                <h2>Not supported here</h2>
                <ul>
${notices.map((n) => `                    <li>${escapeZigString(n)}</li>`).join("\n")}
                </ul>
            </div>`
            : "";

    const linksBlock =
        links.length > 0
            ? `
            <div>
                <h2>Try these paths</h2>
                <ul>
${linkItems}
                </ul>
            </div>`
            : `
            <p>Edit files under <code>app/</code> and run to preview.</p>`;

    return `pub fn Page(ctx: zx.PageContext) !zx.Component {
    return (
        <main @allocator={ctx.arena}>
            <h1>Playground</h1>
            <p>Minimal app shell for this snippet.</p>
${linksBlock}
${noticeBlock}
        </main>
    );
}

const zx = @import("zx");
`;
}

function ensureMinimalAppShell(files: PlaygroundFilesMap): PlaygroundFilesMap {
    const out: PlaygroundFilesMap = { ...files };

    if (!out["app/pages/layout.zx"]) {
        out["app/pages/layout.zx"] = MINIMAL_LAYOUT;
    }

    const unsupported = detectUnsupportedFeatures(out);
    const nonRootLinks = collectExampleLinks(out);
    const hasUnsupported =
        unsupported.caching || unsupported.websocket || unsupported.nonGetMethods.length > 0;
    const needsSampleHome = !out["app/pages/page.zx"] || nonRootLinks.length > 0 || hasUnsupported;

    // If the snippet already owns `/` but we need a sample home (links/notices),
    // move it to /demo so the generated home can point at it.
    if (needsSampleHome && out["app/pages/page.zx"]) {
        if (!out["app/pages/demo/page.zx"]) {
            out["app/pages/demo/page.zx"] = out["app/pages/page.zx"];
        }
        delete out["app/pages/page.zx"];
    }

    if (!out["app/pages/page.zx"]) {
        out["app/pages/page.zx"] = buildSampleHomePage(out);
    }

    return out;
}

/**
 * Pack one or more docs/home snippets into a playground file map.
 * Route handlers and client/page/layout snippets open in app mode with a minimal shell.
 */
export function createDocsSnippetFiles(code: string, filename = "Playground.zx"): PlaygroundFilesMap {
    return createDocsSnippetFilesFromEntries([{ code, filename }]);
}

export function createDocsSnippetFilesFromEntries(entries: SnippetEntry[]): PlaygroundFilesMap {
    const cleaned = entries
        .map((entry) => ({
            code: entry.code.trim(),
            filename: entry.filename.trim() || "Playground.zx",
        }))
        .filter((entry) => entry.code.length > 0);

    if (cleaned.length === 0) {
        return { "Playground.zx": "" };
    }

    const useApp = cleaned.some((entry) => needsAppMode(entry.code, entry.filename));

    if (!useApp) {
        const primary = cleaned[0];
        return {
            "Playground.zx": processSnippetCode(primary.code),
        };
    }

    const files: PlaygroundFilesMap = {};

    for (const entry of cleaned) {
        let code = processSnippetCode(entry.code);
        const path = mapEntryToAppPath(entry.filename, code);

        if (path.endsWith("/page.zx") || path === "app/pages/page.zx") {
            if (!hasPageExport(code) && !looksLikeRoute(code, entry.filename)) {
                code = processSnippetCode(wrapComponentAsPage(code));
            }
        }

        // Prefer keeping an existing page/layout/route if multiple entries map to the same path.
        if (!files[path]) {
            files[path] = code;
        }
    }

    return ensureMinimalAppShell(files);
}

export async function encodeFilesToQuery(filesMap: PlaygroundFilesMap): Promise<string> {
    const json = JSON.stringify(filesMap);
    const stream = new Blob([json]).stream().pipeThrough(new CompressionStream("deflate"));
    const buffer = await new Response(stream).arrayBuffer();

    let binString = "";
    const bytes = new Uint8Array(buffer);
    const CHUNK_SIZE = 0x8000;
    for (let i = 0; i < bytes.length; i += CHUNK_SIZE) {
        binString += String.fromCharCode.apply(null, Array.from(bytes.subarray(i, i + CHUNK_SIZE)));
    }

    const b64 = btoa(binString);
    return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function decodeFilesFromQuery(query: string): Promise<PlaygroundFilesMap | null> {
    try {
        let b64 = query.replace(/-/g, "+").replace(/_/g, "/");
        while (b64.length % 4) {
            b64 += "=";
        }

        const binString = atob(b64);
        const bytes = Uint8Array.from(binString, (m) => m.codePointAt(0) ?? 0);
        const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate"));
        const text = await new Response(stream).text();

        return JSON.parse(text) as PlaygroundFilesMap;
    } catch {
        return null;
    }
}

export async function createPlaygroundShareUrl(filesMap: PlaygroundFilesMap, baseUrl: string): Promise<string> {
    const encoded = await encodeFilesToQuery(filesMap);
    return `${baseUrl}#data=${encoded}`;
}
