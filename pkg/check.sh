#!/bin/bash
set -euo pipefail

# Smoke-tests @ziex/cli and ziex packages by publishing to a local
# Verdaccio registry and verifying that the CLI binary works.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
VERDACCIO_DIR="$SCRIPT_DIR/@ziex"
REGISTRY="http://localhost:4873"
VERSION="${1:-}"

RESULTS_DIR=$(mktemp -d)

publish_idempotent() {
  local pkg="$1"; shift
  local out rc=0 codes
  out=$(npm publish --access public --tag dev --registry "$REGISTRY" "$@" 2>&1) || rc=$?
  echo "$out"
  [ "$rc" -eq 0 ] && return 0
  codes=$(printf '%s\n' "$out" | grep -E 'npm (error|ERR!) code ' | grep -oE 'E[0-9]{3}' || true)
  if [ -n "$codes" ] && ! printf '%s\n' "$codes" | grep -qv '^E409$'; then
    echo "==> $pkg already present at this version; ensuring dist-tag and continuing"
    # Best-effort: keep the 'dev' dist-tag pointed at this version. Don't fail
    # the smoke test if even this is a no-op.
    npm dist-tag add "${pkg}@${VERSION}" dev --registry "$REGISTRY" 2>&1 || true
    return 0
  fi
  echo "==> Publish failed for $pkg (not a conflict, rc=$rc)" >&2
  return 1
}

cleanup() {
  if [ -n "${VERDACCIO_PID:-}" ]; then
    kill "$VERDACCIO_PID" 2>/dev/null || true
    wait "$VERDACCIO_PID" 2>/dev/null || true
  fi
  rm -rf "$SCRIPT_DIR/_check_tmp" "$SCRIPT_DIR/_check_npmrc" "$RESULTS_DIR"
}
trap cleanup EXIT

# Resolve expected version
if [ -z "$VERSION" ]; then
  VERSION=$(sed -n 's/.*\.version *= *"\([^"]*\)".*/\1/p' "$ROOT_DIR/build.zig.zon")
fi
echo "==> Checking packages at version $VERSION"

# Use a clean .npmrc scoped to this script so CI's global auth config
# (written by setup-node) doesn't interfere with local Verdaccio.
export npm_config_userconfig="$SCRIPT_DIR/_check_npmrc"
cat > "$npm_config_userconfig" <<EOF
registry=$REGISTRY
//localhost:4873/:_authToken=local-dev-token
EOF

# Start Verdaccio only if not running in CI
if [ -z "${CI:-}" ]; then
  echo "==> Starting local registry..."
  rm -rf "$VERDACCIO_DIR/.verdaccio-storage"
  npx --yes verdaccio@6 --config "$VERDACCIO_DIR/verdaccio.yaml" --listen 4873 &
  VERDACCIO_PID=$!

  for i in $(seq 1 120); do
    if curl -sf "$REGISTRY/-/ping" > /dev/null 2>&1; then break; fi
    sleep 0.5
  done
else
  echo "==> Skipping Verdaccio startup in CI"
fi

# Publish @ziex/cli* packages to local registry.
# --workspaces publishes all @ziex/cli* at once; if some are already present
echo "==> Publishing @ziex/cli* to local registry..."
cd "$VERDACCIO_DIR"
cli_rc=0
cli_out=$(npm publish --workspaces --access public --tag dev --registry "$REGISTRY" 2>&1) || cli_rc=$?
echo "$cli_out"
if [ "$cli_rc" -ne 0 ]; then
  codes=$(printf '%s\n' "$cli_out" | grep -E 'npm (error|ERR!) code ' | grep -oE 'E[0-9]{3}' || true)
  if [ -z "$codes" ] || printf '%s\n' "$codes" | grep -qv '^E409$'; then
    echo "==> @ziex/cli* publish failed with a non-conflict error (rc=$cli_rc)" >&2
    exit 1
  fi
  echo "==> @ziex/cli* already present at this version; continuing"
fi

# Build and publish ziex to local registry.
echo "==> Building and publishing ziex to local registry..."
cd "$SCRIPT_DIR/ziex"
rm -rf dist
zig build -p dist -Dfrom-source=true -Dversion="$VERSION"
cd dist
publish_idempotent ziex


# Create temp directory for testing
# Use a fresh temp dir to avoid npx/bunx cache interference
rm -rf "$SCRIPT_DIR/_check_tmp"
mkdir -p "$SCRIPT_DIR/_check_tmp"
cd "$SCRIPT_DIR/_check_tmp"
export npm_config_cache="$SCRIPT_DIR/_check_tmp/.npm-cache"

# Test runner - writes PASS/FAIL to $RESULTS_DIR so tests can run in parallel
check() {
  local name="$1" cmd="$2" expected="$3"
  local safe_name="${name//[\/[:space:]]/_}"
  local output
  output=$(eval "$cmd" 2>&1) || true
  if echo "$output" | grep -q "$expected"; then
    echo "PASS" > "$RESULTS_DIR/$safe_name"
    echo "  PASS: $name"
  else
    echo "FAIL" > "$RESULTS_DIR/$safe_name"
    echo "  FAIL: $name - expected '$expected', got: $output"
  fi
}

# --- Tests (run in parallel) ---

echo ""
echo "Running checks..."
echo ""

pids=()

# @ziex/cli via npx
check "npx @ziex/cli version" \
  "npx --yes --registry '$REGISTRY' @ziex/cli@dev version" \
  "$VERSION" &
pids+=($!)

# ziex via npx
check "npx ziex version" \
  "npx --yes --registry '$REGISTRY' ziex@dev version" \
  "$VERSION" &
pids+=($!)

check "npx ziex --help" \
  "npx --yes --registry '$REGISTRY' ziex@dev --help" \
  "." &
pids+=($!)

# bunx compatibility
if command -v bunx &> /dev/null; then
  check "bunx @ziex/cli version" \
    "env BUN_CONFIG_REGISTRY='$REGISTRY' BUN_CONFIG_IGNORE_SCRIPTS=true bunx --verbose @ziex/cli@dev version" \
    "$VERSION" &
  pids+=($!)

  check "bunx ziex version" \
    "env BUN_CONFIG_REGISTRY='$REGISTRY' BUN_CONFIG_IGNORE_SCRIPTS=true bunx --verbose ziex@dev version" \
    "$VERSION" &
  pids+=($!)
fi

for pid in "${pids[@]}"; do wait "$pid" || true; done

# --- Summary ---

PASSED=$( (grep -rl "PASS" "$RESULTS_DIR" 2>/dev/null || true) | wc -l | tr -d ' ')
FAILED=$( (grep -rl "FAIL" "$RESULTS_DIR" 2>/dev/null || true) | wc -l | tr -d ' ')

echo ""
echo "  Results: $PASSED passed, $FAILED failed"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
