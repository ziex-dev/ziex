import { PORT_NAME, type DevtoolsInitMessage, type LogMessage, type NavigationMessage } from './shared';

// Devtools page port per inspected tab, used to forward SPA navigations.
const ports = new Map<number, chrome.runtime.Port>();

chrome.runtime.onConnect.addListener((port) => {
    if (port.name !== PORT_NAME) return;
    port.onMessage.addListener((msg: DevtoolsInitMessage) => {
        if (msg.type !== 'zx-devtools-init') return;
        ports.set(msg.tabId, port);
        port.onDisconnect.addListener(() => {
            if (ports.get(msg.tabId) === port) ports.delete(msg.tabId);
        });
    });
});

chrome.runtime.onMessage.addListener((msg: NavigationMessage | LogMessage, sender) => {
    if (msg.type === 'zx-log') {
        (msg.level === 'error' ? console.error : console.info)(`[${msg.source}] ${msg.text}`);
        return;
    }
    const tabId = sender.tab?.id;
    if (msg.type !== 'zx-navigation' || tabId == null) return;
    ports.get(tabId)?.postMessage(msg);
});
