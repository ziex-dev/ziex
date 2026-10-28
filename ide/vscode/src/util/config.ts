// @ts-ignore
import * as os from "os";
// @ts-ignore
import * as path from "path";
import { Uri, workspace, WorkspaceConfiguration } from "vscode";
import type { Middleware } from "vscode-languageclient/node";

/// Section the embedded ZLS pulls with `workspace/configuration`.
const ZLS_SECTION = "zls";

/// `ziex.lsp.<key>` settings forwarded to ZLS as `<snake_case key>`. Each falls
/// back to the official Zig extension's `zig.zls.<key>` (or the given key).
const OPTIONS: Record<string, string> = {
  enableSnippets: "zls.enableSnippets",
  enableArgumentPlaceholders: "zls.enableArgumentPlaceholders",
  completionLabelDetails: "zls.completionLabelDetails",
  semanticTokens: "zls.semanticTokens",
  inlayHintsShowVariableTypeHints: "zls.inlayHintsShowVariableTypeHints",
  inlayHintsShowStructLiteralFieldType: "zls.inlayHintsShowStructLiteralFieldType",
  inlayHintsShowParameterName: "zls.inlayHintsShowParameterName",
  inlayHintsShowBuiltin: "zls.inlayHintsShowBuiltin",
  inlayHintsExcludeSingleArgument: "zls.inlayHintsExcludeSingleArgument",
  inlayHintsHideRedundantParamNames: "zls.inlayHintsHideRedundantParamNames",
  inlayHintsHideRedundantParamNamesLastToken: "zls.inlayHintsHideRedundantParamNamesLastToken",
  builtinPath: "zls.builtinPath",
  zigLibPath: "libPath",
  globalCachePath: "zls.globalCachePath",
};

const PATH_OPTIONS = new Set(["builtinPath", "zigLibPath", "globalCachePath"]);

/// Derived from each project's `build.zig` by `zx lsp`; never sent from settings.
const RESERVED = new Set(["modules", "import_extensions"]);

/**
 * Answers the server's `workspace/configuration` request for the `zls`
 * section from `ziex.lsp.*`, falling back to `zig.zls.*`. Only values the user
 * set explicitly are sent, so unset options keep the server's Ziex defaults.
 */
export function configurationMiddleware(getZig: () => string | undefined): Middleware {
  return {
    workspace: {
      configuration: async (params, token, next) => {
        const result = await next(params, token);
        if (!Array.isArray(result)) return result;
        return params.items.map((item, i) =>
          item.section === ZLS_SECTION
            ? zlsSettings(item.scopeUri ? Uri.parse(item.scopeUri) : undefined, getZig())
            : result[i],
        );
      },
    },
  };
}

function zlsSettings(scope: Uri | undefined, zig: string | undefined): Record<string, unknown> {
  const ziex = workspace.getConfiguration("ziex.lsp", scope);
  const zigConfig = workspace.getConfiguration("zig", scope);
  const folder = (scope && workspace.getWorkspaceFolder(scope)?.uri.fsPath) ??
    workspace.workspaceFolders?.[0]?.uri.fsPath;

  const settings: Record<string, unknown> = {};
  // Lowest to highest precedence.
  Object.assign(settings, zigAdditionalOptions(zigConfig));
  Object.assign(settings, ziex.get<Record<string, unknown>>("additionalOptions") ?? {});

  for (const [key, fallback] of Object.entries(OPTIONS)) {
    let value = explicitValue(ziex, key) ?? explicitValue(zigConfig, fallback);
    if (value === undefined) continue;
    if (PATH_OPTIONS.has(key) && typeof value === "string") {
      if (!value) continue;
      value = resolvePath(value, folder);
    }
    settings[toSnakeCase(key)] = value;
  }

  if (settings.zig_exe_path === undefined && zig && path.isAbsolute(zig)) {
    settings.zig_exe_path = zig;
  }
  for (const key of RESERVED) delete settings[key];
  return settings;
}

/// `zig.zls.additionalOptions` uses keys like `zig.zls.someOption`.
function zigAdditionalOptions(zigConfig: WorkspaceConfiguration): Record<string, unknown> {
  const options = zigConfig.get<Record<string, unknown>>("zls.additionalOptions") ?? {};
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(options)) {
    if (key.startsWith("zig.zls.")) out[toSnakeCase(key.slice("zig.zls.".length))] = value;
  }
  return out;
}

/// The value the user set (folder > workspace > user), ignoring schema defaults.
function explicitValue(config: WorkspaceConfiguration, key: string): unknown {
  const inspected = config.inspect(key);
  return inspected?.workspaceFolderValue ?? inspected?.workspaceValue ?? inspected?.globalValue;
}

/// Expands `~` and `${workspaceFolder}`, and makes relative paths workspace-relative.
export function resolvePath(value: string, folder?: string): string {
  let resolved = value
    .replace(/\$\{workspaceFolder\}/g, folder ?? "")
    .replace(/^~(?=$|[\\/])/, os.homedir());
  if (!path.isAbsolute(resolved) && folder) resolved = path.join(folder, resolved);
  return resolved;
}

function toSnakeCase(key: string): string {
  return key.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`);
}
