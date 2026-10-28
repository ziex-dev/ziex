import { PAGE_NAVIGATION_EVENT, type NavigationMessage } from './shared';

// Safari has no MAIN world content scripts, so load page.js through a script tag.
if (__BROWSER__ === 'safari') {
    const script = document.createElement('script');
    script.src = chrome.runtime.getURL('scripts/page.js');
    script.onload = () => script.remove();
    document.documentElement.append(script);
}

// Forwards SPA navigations seen by page.ts to the background worker.
window.addEventListener(PAGE_NAVIGATION_EVENT, () => {
    const message: NavigationMessage = { type: 'zx-navigation', href: location.href };
    try {
        chrome.runtime.sendMessage(message).catch(() => {});
    } catch {
        // Extension was reloaded; this content script is orphaned.
    }
});
