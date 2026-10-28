# Ziex DevTools

The Ziex DevTools panel is a Ziex app. It ships as a browser extension for
Chrome, Firefox and Safari, and as a website (devtool.ziex.dev).

```
app/                  panel app (pages, client.ts)
extension/
  background.ts       relays SPA navigations and logs
  content.ts          isolated-world bridge (in Safari, it also injects page.js)
  page.ts             page-world history hook
  devtools.ts         devtools page: adds the panel, runs evals for it
  shared.ts           message types, error forwarding
  manifest.zig        manifests for each browser, plus the Safari plists
  safari.swift        Safari container app and extension
```

The panel never calls devtools APIs directly, because Safari kills a panel that
does. It sends its evals to the devtools page, and the devtools page forwards
navigations back to it.

## Build

```sh
zig build extension -Doptimize=ReleaseSmall   # or: chromium / firefox / safari
```

This outputs:

- `zig-out/{chromium,firefox,safari}/`: the unpacked extensions
- `zig-out/ziex-devtools-{chromium,firefox}.zip`: the store uploads
- `zig-out/Ziex DevTools.app` and `ziex-devtools-safari.zip`: the Safari app,
  built on macOS only

Notes:

- **Version:** comes from `build.zig.zon`.
- **Browser-specific code:** each browser's scripts are built with
  `__BROWSER__` defined, so the other browsers' branches are removed.
- **Safari app:** built with `swiftc` and `codesign` from Xcode's command line
  tools. It is ad-hoc signed and not notarized.
- **Type check:** `npm install && npm run typecheck`.

## Test locally

Open DevTools on a Ziex app (e.g. one running `zx dev`). The Ziex tab appears
once Ziex is detected on the page.

- **Chrome:** at `chrome://extensions`, enable Developer mode, click "Load
  unpacked" and pick `zig-out/chromium`.
- **Firefox (140+):** at `about:debugging#/runtime/this-firefox`, click "Load
  Temporary Add-on" and pick `zig-out/firefox/manifest.json`.
- **Safari:** run `zig build safari && open "zig-out/Ziex DevTools.app"`, then
  follow steps 3-5 of [Installing in Safari](#installing-in-safari).

After rebuilding, reload the extension: use the reload button in Chrome or
Firefox, or reopen the app for Safari.

Errors from the panel and the devtools page appear in the background console.
In Safari, open it from Develop > Web Extension Background Content.

## Publish

1. Bump `.version` in `build.zig.zon`, then build.
2. **Chrome:** upload `ziex-devtools-chromium.zip` in the
   [developer dashboard](https://chrome.google.com/webstore/devconsole). The
   extension requests no permissions; keep it that way, since the store rejects
   unused ones.
3. **Firefox:** upload `ziex-devtools-firefox.zip` on
   [AMO](https://addons.mozilla.org/developers/) (add-on ID `devtools@ziex.dev`).
   Because the scripts are minified, also upload an archive of `ide/devtool` as
   the source, with the build command as the instructions.
4. **Safari:** attach `ziex-devtools-safari.zip` to the GitHub release. An App
   Store listing needs a paid Apple Developer account.

### Installing in Safari

1. Unzip `ziex-devtools-safari.zip` and move `Ziex DevTools.app` to `/Applications`.
2. Remove the download quarantine (the app isn't notarized) and open the app:

   ```sh
   xattr -cr "/Applications/Ziex DevTools.app" && open "/Applications/Ziex DevTools.app"
   ```

3. In Safari, go to Settings > Advanced and enable "Show features for web developers".
4. Go to Develop > Developer Settings and enable "Allow unsigned extensions".
   Safari turns this off when it quits, so repeat this step after each restart.
5. Go to Settings > Extensions and enable Ziex DevTools.
