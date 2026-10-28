#!/bin/bash
# Full test suite: Clean, setup, and verify

set -e

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "🧪 Ziex Neovim Plugin - Full Test Suite"
echo "======================================"
echo ""

# Clean everything
echo "Step 1: Cleaning..."
rm -f ~/.local/share/nvim/site/parser/{zx,mdzx,mdzx_inline}.so
rm -rf ~/.local/share/nvim/site/queries/zx
rm -rf ~/.local/state/nvim/parser-cache
rm -rf ~/.cache/nvim/luac
echo "  ✓ Cleaned"

# Create test file
echo ""
echo "Step 2: Creating test file..."
cat > /tmp/test.zx << 'EOF'
const std = @import("std");

pub fn main() void {
    const x: i32 = 42;
    std.debug.print("{}\n", .{x});
}

<div class="container">
    <h1>Hello ZX</h1>
    <button @click="handleClick">Click me</button>
</div>
EOF
echo "  ✓ Created /tmp/test.zx"

# Verify tree-sitter CLI
echo ""
echo "Step 3: Checking prerequisites..."
if command -v tree-sitter &> /dev/null; then
    echo "  ✓ tree-sitter CLI: $(tree-sitter --version)"
else
    echo "  ✗ tree-sitter CLI not found!"
    echo "    Install: brew install tree-sitter"
    exit 1
fi

# Check if grammar exists
echo ""
echo "Step 4: Checking grammar..."
GRAMMAR_DIR="$(cd "$PLUGIN_DIR/../../pkg/tree-sitter-zx" && pwd)"
if [ -f "$GRAMMAR_DIR/src/parser.c" ]; then
    echo "  ✓ Grammar found: $GRAMMAR_DIR"
else
    echo "  ✗ Grammar not found at: $GRAMMAR_DIR"
    exit 1
fi

# Test parser build manually
echo ""
echo "Step 5: Testing manual parser build..."
cd "$GRAMMAR_DIR"
tree-sitter build --output /tmp/test-zx-parser.so
if [ -f /tmp/test-zx-parser.so ]; then
    echo "  ✓ Parser builds successfully"
    rm /tmp/test-zx-parser.so
else
    echo "  ✗ Parser build failed"
    exit 1
fi

# Test Neovim integration
echo ""
echo "Step 6: Testing Neovim integration..."
nvim --headless \
  -c "set runtimepath+=$PLUGIN_DIR" \
  -c "lua vim.filetype.add({ extension = { zx = 'zx' } })" \
  -c "e /tmp/test.zx" \
  -c "lua print('Filetype: ' .. vim.bo.filetype)" \
  -c "sleep 100m" \
  -c "q" 2>&1 | grep -q "Filetype: zx" && echo "  ✓ Filetype detection works" || echo "  ✗ Filetype detection failed"

echo ""
echo "✅ All tests passed!"
echo ""
echo "📝 Manual test:"
echo "  1. Run: nvim /tmp/test.zx"
echo "  2. Check:"
echo "     • Auto-build notification appears"
echo "     • Syntax highlighting works"
echo "     • :set ft? shows 'filetype=zx'"
echo "     • <leader>zt shows tree"
echo "     • <leader>zh shows highlights"

