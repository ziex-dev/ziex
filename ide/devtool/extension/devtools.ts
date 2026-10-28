import {
    PORT_NAME,
    reportErrors,
    type DevtoolsInitMessage,
    type EvalRequest,
    type EvalResponse,
    type NavigationMessage,
    type PanelNavigationMessage,
} from './shared';

reportErrors('devtools');

const MAX_CHECKS = 10;

const tabId = chrome.devtools.inspectedWindow.tabId;

let panelCreated = false;
let checks = 0;
let checkTimer: ReturnType<typeof setInterval> | undefined;

// Ziex pages expose a global hook; only add the panel once it shows up.
function detectZiex() {
    if (panelCreated || ++checks > MAX_CHECKS) return stopChecking();
    chrome.devtools.inspectedWindow.eval<boolean>('!!window.__ZIEX_DEVTOOLS_GLOBAL_HOOK__', (detected, error) => {
        if (!error && detected && !panelCreated) createPanel();
    });
}

function startChecking() {
    stopChecking();
    checks = 0;
    detectZiex();
    checkTimer = setInterval(detectZiex, 1000);
}

function stopChecking() {
    clearInterval(checkTimer);
    checkTimer = undefined;
}

function createPanel() {
    panelCreated = true;
    stopChecking();
    chrome.devtools.panels.create('Ziex', '/pages/assets/branding/ziex-logo-colored-128x128.png', '/pages/index.html');
}

function notifyPanel(href: string) {
    const message: PanelNavigationMessage = { type: 'zx-panel-navigation', tabId, href };
    chrome.runtime.sendMessage(message).catch(() => {});
}

// The background worker can be suspended, which drops the port, so reconnect.
function connectBackground() {
    const port = chrome.runtime.connect({ name: PORT_NAME });
    port.postMessage({ type: 'zx-devtools-init', tabId } satisfies DevtoolsInitMessage);
    port.onMessage.addListener((msg: NavigationMessage) => {
        if (msg.type === 'zx-navigation') notifyPanel(msg.href);
    });
    port.onDisconnect.addListener(connectBackground);
}

chrome.runtime.onMessage.addListener((msg: EvalRequest, _sender, sendResponse: (response: EvalResponse) => void) => {
    if (msg.type !== 'zx-eval' || msg.tabId !== tabId) return;
    chrome.devtools.inspectedWindow.eval(msg.expression, (result, error) => {
        sendResponse(error ? { error: String(error.value ?? error.description ?? 'eval failed') } : { result });
    });
    return true;
});

chrome.devtools.network.onNavigated.addListener((href) => {
    if (!panelCreated) startChecking();
    notifyPanel(href);
});

startChecking();
connectBackground();
