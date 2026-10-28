// Set per browser by esbuild, so each build drops the other browsers' code.
declare global {
    const __BROWSER__: 'chromium' | 'firefox' | 'safari';
}

// Port between the devtools page and the background worker.
export const PORT_NAME = 'zx-devtools';

// DOM event from page.ts (page world) to content.ts (isolated world).
export const PAGE_NAVIGATION_EVENT = 'zx-page-navigation';

export type DevtoolsInitMessage = { type: 'zx-devtools-init'; tabId: number };
export type NavigationMessage = { type: 'zx-navigation'; href: string };
export type LogMessage = { type: 'zx-log'; source: string; level: 'info' | 'error'; text: string };

// The panel never calls devtools APIs itself (Safari kills a panel that does);
// the devtools page evaluates for it and forwards navigations.
export type EvalRequest = { type: 'zx-eval'; tabId: number; expression: string };
export type EvalResponse = { result?: unknown; error?: string };
export type PanelNavigationMessage = { type: 'zx-panel-navigation'; tabId: number; href: string };

// Forwards errors to the background worker, whose console stays open (Develop >
// Web Extension Background Content in Safari) even when the panel or devtools page dies.
export function reportErrors(source: string) {
    const send = (level: LogMessage['level'], text: string) => {
        const message: LogMessage = { type: 'zx-log', source, level, text };
        try {
            chrome.runtime.sendMessage(message).catch(() => {});
        } catch {
            // Extension context is gone
        }
    };
    const describe = (value: unknown) =>
        value instanceof Error ? `${value.message}\n${value.stack ?? ''}` : String(value);

    window.addEventListener('error', (e) => send('error', `${e.message} (${e.filename}:${e.lineno})\n${describe(e.error)}`));
    window.addEventListener('unhandledrejection', (e) => send('error', `Unhandled rejection: ${describe(e.reason)}`));
    const consoleError = console.error;
    console.error = (...args: unknown[]) => {
        send('error', args.map(describe).join(' '));
        consoleError.apply(console, args);
    };
}
