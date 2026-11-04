const { readFileSync, writeFileSync, mkdirSync, readdirSync } = require("fs");
const { dirname, resolve, join, sep } = require("path");

function loadTailwindNode() {
    try {
        return require("@tailwindcss/node");
    } catch (err) {
        const detail = err instanceof Error ? err.message : String(err);
        const missing =
            err && typeof err === "object" && "code" in err && err.code === "MODULE_NOT_FOUND";
        const hint = missing
            ? "Install Tailwind in the app (npm i -D tailwindcss @tailwindcss/node) and run from a directory that can resolve those packages."
            : detail;
        throw new Error(`failed to load @tailwindcss/node: ${hint}`);
    }
}

function writeLine(event) {
    process.stdout.write(JSON.stringify(event) + "\n");
}

function normalizeForGlob(path) {
    return path.split(sep).join("/");
}

function escapeRegExp(value) {
    return value.replace(/[|\\{}()[\]^$+?.]/g, "\\$&");
}

function globToRegExp(glob) {
    let pattern = "^";
    for (let i = 0; i < glob.length; i++) {
        const char = glob[i];
        if (char === "*") {
            if (glob[i + 1] === "*") {
                i += 1;
                if (glob[i + 1] === "/") {
                    i += 1;
                    pattern += "(?:.*/)?";
                } else {
                    pattern += ".*";
                }
            } else {
                pattern += "[^/]*";
            }
        } else if (char === "?") {
            pattern += "[^/]";
        } else {
            pattern += escapeRegExp(char);
        }
    }
    return new RegExp(pattern + "$");
}

function getPatternRoot(base, pattern) {
    const normalized = normalizeForGlob(pattern).replace(/^\.\//, "");
    const parts = normalized.split("/");
    const literal = [];
    for (const part of parts) {
        if (part === "" || part.includes("*") || part.includes("?")) break;
        literal.push(part);
    }
    return literal.length > 0 ? resolve(base, literal.join("/")) : resolve(base);
}

function collectMatchingFiles(root, matcher, results) {
    try {
        const entries = readdirSync(root, { withFileTypes: true });
        for (const entry of entries) {
            const full = join(root, entry.name);
            if (entry.isDirectory()) {
                if (entry.name === "node_modules" || entry.name === ".git" || entry.name.startsWith(".")) continue;
                collectMatchingFiles(full, matcher, results);
            } else if (entry.isFile() && matcher(full)) {
                results.push(full);
            }
        }
    } catch {}
}

function listFilesMatching(base, pattern) {
    const normalizedPattern = normalizeForGlob(pattern);
    if (normalizedPattern === "./" || normalizedPattern === ".") {
        const results = [];
        collectMatchingFiles(resolve(base), () => true, results);
        return results;
    }

    const fullPattern = normalizeForGlob(resolve(base, normalizedPattern.replace(/^\.\//, "")));
    const matcher = globToRegExp(fullPattern);
    const results = [];
    collectMatchingFiles(getPatternRoot(base, normalizedPattern), (file) => matcher.test(normalizeForGlob(file)), results);
    return results;
}

/**
 * Extract candidate class names from file content.
 */
function extractCandidates(content) {
    const matches = content.matchAll(/[a-zA-Z0-9_\-\/:.!\[\]#%]+/g);
    const result = [];
    for (const match of matches) {
        result.push(match[0]);
    }
    return result;
}

function formatError(err) {
    if (!(err instanceof Error)) return String(err);
    // Prefer message; append stack first frame for actionable diagnostics.
    const stack_line = err.stack?.split("\n")[1]?.trim();
    return stack_line ? `${err.message} (${stack_line})` : err.message;
}

async function runBuild(tw, { id, name, config }, index) {
    id = id ?? index;
    const { compile, optimize } = tw;

    writeLine({ id, type: "start", name });
    try {
        // enhanced-resolve (used by @tailwindcss/node) requires absolute bases.
        const input = resolve(config.input);
        const output = resolve(config.output);
        const base = resolve(config.base ?? dirname(input));

        const css = readFileSync(input, "utf-8");

        const dependencies = [];
        const compiler = await compile(css, {
            base,
            from: input,
            onDependency: (path) => dependencies.push(path),
        });

        // Collect candidates from source files
        const candidates = new Set();

        // Scan files from compiler-detected sources using Tailwind's own discovered patterns.
        for (const source of compiler.sources ?? []) {
            if (source.negated) continue;
            const files = listFilesMatching(source.base, source.pattern);
            for (const file of files) {
                try {
                    const content = readFileSync(file, "utf-8");
                    for (const c of extractCandidates(content)) {
                        candidates.add(c);
                    }
                    dependencies.push(file);
                } catch {}
            }
        }

        // Scan additional user-specified source paths
        if (config.sources) {
            for (const sourcePath of config.sources) {
                try {
                    const abs = resolve(sourcePath);
                    const content = readFileSync(abs, "utf-8");
                    for (const c of extractCandidates(content)) {
                        candidates.add(c);
                    }
                    dependencies.push(abs);
                } catch {}
            }
        }

        const built = compiler.build([...candidates]);

        let result = built;
        if (config.optimize || config.minify) {
            const optimized = optimize(result, {
                file: output,
                minify: config.minify,
            });
            result = optimized.code;
        }

        mkdirSync(dirname(output), { recursive: true });
        writeFileSync(output, result);

        writeLine({ id, type: "result", name, success: true, output, dependencies });
    } catch (err) {
        writeLine({
            id,
            type: "error",
            name,
            error: formatError(err),
        });
    } finally {
        writeLine({ id, type: "end", name });
    }
}

async function main() {
    const tw = loadTailwindNode();

    // Read stdin as JSON (Node.js compatible)
    const chunks = [];
    for await (const chunk of process.stdin) {
        chunks.push(chunk);
    }
    const builds = JSON.parse(Buffer.concat(chunks).toString("utf-8"));
    if (!Array.isArray(builds)) {
        throw new Error("expected a JSON array of builds on stdin");
    }
    await Promise.allSettled(builds.map((build, index) => runBuild(tw, build, index)));
}

main().catch((err) => {
    process.stderr.write(`ziex-plugin-tailwindcss: fatal: ${formatError(err)}\n`);
    process.exit(1);
});
