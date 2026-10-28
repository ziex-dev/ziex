// @ts-ignore
import * as childProcess from "child_process";
// @ts-ignore
import * as util from "util";
// @ts-ignore
import * as fs from "fs";
// @ts-ignore
import * as os from "os";
// @ts-ignore
import * as path from "path";
import { ExtensionContext, TextDocument, Uri, window, workspace } from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions
} from "vscode-languageclient/node";

import { activateMultilineStringDecorator } from "./util/string";
import { configurationMiddleware } from "./util/config";
import { envWithZig, findZigExecutable } from "./util/zig";

let client: LanguageClient | undefined;
let starting: Promise<void> | undefined;
let warned = false;
const execFile = util.promisify(childProcess.execFile);

export async function activate(context: ExtensionContext) {
  activateMultilineStringDecorator(context);

  // The extension also activates for `.zig` files (e.g. a Zig monorepo that is
  // not a Ziex project), so the server is only started once a `.zx` file is
  // open, resolving the project from that file. Failed attempts are retried
  // on the next `.zx` file, which may belong to a Ziex subproject.
  const onDocument = (doc: TextDocument) => {
    if (isZiexDoc(doc) && doc.uri.scheme === "file") {
      void ensureClient(context, doc.uri.fsPath);
    }
  };
  context.subscriptions.push(workspace.onDidOpenTextDocument(onDocument));
  workspace.textDocuments.forEach(onDocument);
}

function isZiexDoc(doc: TextDocument): boolean {
  return doc.languageId === "zx" || doc.languageId === "mdzx";
}

function ensureClient(context: ExtensionContext, file: string): Promise<void> {
  if (client) return Promise.resolve();
  starting ??= startClient(context, file).finally(() => {
    starting = undefined;
  });
  return starting;
}

async function startClient(context: ExtensionContext, file: string): Promise<void> {
  const lspCmd = await getLspCommand(context, file);
  if (!lspCmd.command) {
    if (!warned) {
      warned = true;
      window.showWarningMessage(
        lspCmd.zig
          ? "Ziex: language server not started. Install the zx CLI, or open a .zx file inside a project whose build.zig has a `zx` step."
          : "Ziex: language server not started. Zig was not found; install Zig, add it to PATH, or set `zig.path`.",
      );
    }
    return;
  }

  const serverOptions: ServerOptions = {
    command: lspCmd.command,
    args: lspCmd.args,
    options: {
      cwd: lspCmd.cwd,
      env: lspCmd.env ? { ...process.env, ...lspCmd.env } : undefined,
    },
  };
  const outputChannel = window.createOutputChannel("Ziex Language Server", {
    log: true,
  });
  context.subscriptions.push(outputChannel);

  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      { scheme: "file", language: "zx" },
      { scheme: "file", language: "mdzx" },
    ],
    traceOutputChannel: outputChannel,
    outputChannel,
    // ZLS settings come from `ziex.lsp.*`, falling back to `zig.zls.*`.
    middleware: configurationMiddleware(() => lspCmd.zig),
  };

  client = new LanguageClient(
    "zxls",
    "Ziex Language Server",
    serverOptions,
    clientOptions,
  );
  await client.start();
}

type LspCommand = {
  command: string;
  args: string[];
  cwd?: string;
  env?: Record<string, string>;
  zig?: string;
};

const isWindows = process.platform === "win32";

/// Resolves how to start the server for the `.zx` file `file`.
/// Returns an empty `command` when neither `zx` nor a `zx` build step is found.
async function getLspCommand(context: ExtensionContext, file: string): Promise<LspCommand> {
  const workspaceDir = workspace.getWorkspaceFolder(Uri.file(file))?.uri.fsPath ??
    workspace.workspaceFolders?.[0]?.uri.fsPath;
  const zig = await findZigExecutable(context, workspaceDir);
  // Child processes (`zx lsp` -> ZLS, `zig build`) resolve `zig` from PATH.
  const zigEnv = zig ? envWithZig(zig) : undefined;

  const projectDir = zig ? await findZxProjectDir(zig, file) : undefined;
  const cwd = projectDir ?? workspaceDir;

  // Prefer installed `zx lsp`. Only then resolve ZIEX_MODULE_PATH via
  // `zig build zx -- env` so we can pass --zx-module.
  const zx = await findZxExecutable(cwd);
  if (zx) {
    const zxModulePath = zig && projectDir
      ? (await readZxModulePath(zig, projectDir)) ?? undefined
      : undefined;
    const args = ["lsp"];
    if (zxModulePath) {
      args.push("--zx-module", zxModulePath);
    }
    return {
      command: zx,
      args,
      cwd,
      env: zxModulePath || zigEnv
        ? { ...zigEnv, ...(zxModulePath ? { ZIEX_MODULE_PATH: zxModulePath } : {}) }
        : undefined,
      zig,
    };
  }

  if (zig && projectDir) {
    return {
      command: zig,
      args: ["build", "zx", "-Dziex-lsp=true", "--release=fast", "--", "lsp"],
      cwd: projectDir,
      env: zigEnv,
      zig,
    };
  }
  return { command: "", args: [], zig };
}

/// Resolves `zx` from PATH, falling back to the default install location
/// (`$ZX_INSTALL/bin` or `~/.zx/bin`). VS Code doesn't always inherit the
/// shell PATH (e.g. WSL remote, or Windows before a restart after install).
async function findZxExecutable(cwd?: string): Promise<string | undefined> {
  const exe = isWindows ? "zx.exe" : "zx";
  const installRoot = process.env.ZX_INSTALL || path.join(os.homedir(), ".zx");
  const candidates = ["zx", path.join(installRoot, "bin", exe)];
  for (const candidate of candidates) {
    try {
      await execFile(candidate, ["version"], {
        cwd,
        maxBuffer: 1024 * 1024,
        timeout: 5000,
      });
      return candidate;
    } catch {
      // try next candidate
    }
  }
  return undefined;
}

/// Finds the directory of the nearest build.zig exposing a `zx` step,
/// starting from `file` (then the active and other open .zx documents) and
/// walking up to its workspace folder, then checking each workspace folder
/// root. Needed for monorepos where the Ziex project isn't at the workspace root.
async function findZxProjectDir(zig: string, file: string): Promise<string | undefined> {
  const folders = workspace.workspaceFolders?.map((f) => f.uri.fsPath) ?? [];
  const startPaths: string[] = [file];

  const active = window.activeTextEditor?.document;
  if (active?.uri.scheme === "file") startPaths.push(active.uri.fsPath);
  for (const doc of workspace.textDocuments) {
    if (doc.uri.scheme === "file" && isZiexDoc(doc)) {
      startPaths.push(doc.uri.fsPath);
    }
  }

  const checked = new Set<string>();
  for (const start of startPaths) {
    const root = folders.find((f) => isSubPath(f, start));
    let dir = path.dirname(start);
    while (true) {
      if (!checked.has(dir)) {
        checked.add(dir);
        if (fs.existsSync(path.join(dir, "build.zig")) && (await hasZxBuildStep(zig, dir))) {
          return dir;
        }
      }
      const parent = path.dirname(dir);
      if (parent === dir || (root && !isSubPath(root, parent))) break;
      dir = parent;
    }
  }

  for (const folder of folders) {
    if (checked.has(folder)) continue;
    if (fs.existsSync(path.join(folder, "build.zig")) && (await hasZxBuildStep(zig, folder))) {
      return folder;
    }
  }
  return undefined;
}

function isSubPath(parent: string, child: string): boolean {
  const rel = path.relative(parent, child);
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

async function readZxModulePath(zig: string, cwd: string): Promise<string | undefined> {
  try {
    const { stdout } = await execFile(
      zig,
      ["build", "zx", "--", "env", "--fmt=json"],
      {
        cwd,
        maxBuffer: 1024 * 1024,
        timeout: 60_000,
      },
    );
    const jsonStart = stdout.indexOf("{");
    const jsonEnd = stdout.lastIndexOf("}");
    if (jsonStart < 0 || jsonEnd < jsonStart) return undefined;
    const parsed = JSON.parse(stdout.slice(jsonStart, jsonEnd + 1)) as {
      zx_module_path?: string | null;
    };
    return parsed.zx_module_path ?? undefined;
  } catch (error: any) {
    // @ts-ignore
    console.error("failed to read zx env", error);
    return undefined;
  }
}

interface BuildStep {
  name: string;
  description: string;
}

function parseBuildSteps(output: string): BuildStep[] {
  const steps: BuildStep[] = [];
  const lines = output.split(/\r?\n/);

  for (const line of lines) {
    if (!line.trim()) continue;
    const trimmed = line.trimStart();

    const parts = trimmed.split(/\s{2,}/);
    if (parts.length >= 2) {
      const namePart = parts[0].replace(/\s*\([^)]+\)\s*$/, "").trim();
      const description = parts.slice(1).join(" ").trim();
      if (namePart && description) {
        steps.push({ name: namePart, description });
      }
    }
  }

  return steps;
}

const zxBuildStepCache = new Map<string, Promise<boolean>>();

function hasZxBuildStep(zig: string, cwd: string): Promise<boolean> {
  const key = `${zig}\0${cwd}`;
  let result = zxBuildStepCache.get(key);
  if (!result) {
    result = listHasZxBuildStep(zig, cwd);
    zxBuildStepCache.set(key, result);
  }
  return result;
}

async function listHasZxBuildStep(zig: string, cwd: string): Promise<boolean> {
  try {
    // A cold `zig build -l` compiles the build runner and may fetch deps,
    // which can take well over 5s (especially on WSL / Windows).
    const { stdout } = await execFile(zig, ["build", "-l"], {
      cwd,
      maxBuffer: 1024 * 1024,
      timeout: 120_000,
    });
    const steps = parseBuildSteps(stdout);
    return steps.some((step) => step.name === "zx");
  } catch (error: any) {
    // @ts-ignore
    console.error(error);
    return false;
  }
}


export async function deactivate(): Promise<void> {
  await starting?.catch(() => {});
  if (client) await client.stop();
}
