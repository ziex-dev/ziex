import { PAGE_NAVIGATION_EVENT } from './shared';

// Runs in the page's own world so it sees the app's history calls,
// which an isolated content script can't patch.
let lastHref = location.href;

function notify() {
    if (location.href === lastHref) return;
    lastHref = location.href;
    window.dispatchEvent(new Event(PAGE_NAVIGATION_EVENT));
}

for (const method of ['pushState', 'replaceState'] as const) {
    const original = history[method];
    history[method] = function (this: History, ...args: Parameters<History['pushState']>) {
        original.apply(this, args);
        notify();
    };
}

window.addEventListener('popstate', notify);
