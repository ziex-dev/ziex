#!/bin/bash

# ─── Config ──────────────────────────────────────────
REQUESTS=10000
CONCURRENCY=50
RUNS=3
RESULTS_FILE="result.csv"
ENDPOINT="ssr"

HOST_PREFIX="http://"
HOST_SUFFIX=""

# ─── Colors ──────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
RED='\033[31m'
NC='\033[0m'

ALL_FRAMEWORKS="ziex jetzig leptos dioxus solidjs nextjs"

# ─── Helpers ─────────────────────────────────────────
get_port() {
    case "$1" in
        ziex)    echo 3000 ;;
        jetzig)  echo 3000 ;;
        leptos)  echo 3000 ;;
        dioxus)  echo 3000 ;;
        solidjs) echo 3000 ;;
        nextjs)  echo 3000 ;;
    esac
}

get_label() {
    case "$1" in
        ziex)    echo "Ziex" ;;
        jetzig)  echo "Jetzig" ;;
        leptos)  echo "Leptos" ;;
        dioxus)  echo "Dioxus" ;;
        nextjs)  echo "Next.js" ;;
        *)       echo "$1" ;;
    esac
}


die() { echo -e "${RED}error:${NC} $1" >&2; exit 1; }

# ─── Parse args ──────────────────────────────────────

# Parse args
IN_CONTAINER=false
QUIET=false
ARGS=()
for arg in "$@"; do
    if [ "$arg" = "--container" ]; then
        IN_CONTAINER=true
    elif [ "$arg" = "--quiet" ]; then
        QUIET=true
    else
        ARGS+=("$arg")
    fi
done

FRAMEWORKS=""
if [ ${#ARGS[@]} -gt 0 ]; then
    for arg in "${ARGS[@]}"; do
        port=$(get_port "$arg" 2>/dev/null)
        [ -n "$port" ] || die "unknown framework '$arg' (available: $ALL_FRAMEWORKS)"
        FRAMEWORKS="$FRAMEWORKS $arg"
    done
    FRAMEWORKS=$(echo "$FRAMEWORKS" | xargs)
else
    FRAMEWORKS="$ALL_FRAMEWORKS"
fi

command -v oha &>/dev/null || die "oha not installed (cargo install oha)"

echo -e "\n${BOLD}Ziex Benchmark Suite${NC}"
echo -e "${DIM}───────────────────────────────────────${NC}\n"

# ─── Build ───────────────────────────────────────────
if [ "$IN_CONTAINER" = false ]; then
    echo -ne "Building images..."
    docker compose build --parallel $FRAMEWORKS &>/dev/null
    echo -e " ${GREEN}✓${NC}\n"
fi

# ─── Prepare CSV ─────────────────────────────────────
running_all=false
[ "$FRAMEWORKS" = "$ALL_FRAMEWORKS" ] && running_all=true

if [ "$running_all" = true ] || [ ! -f "$RESULTS_FILE" ]; then
    echo "framework,rps,p50_ms,p99_ms" > "$RESULTS_FILE"
else
    # Preserve results for frameworks not being re-benchmarked
    tmpfile=$(mktemp)
    head -1 "$RESULTS_FILE" > "$tmpfile"
    tail -n +2 "$RESULTS_FILE" | while IFS=',' read -r fw rest; do
        skip=false
        for target in $FRAMEWORKS; do
            [ "$fw" = "$target" ] && { skip=true; break; }
        done
        $skip || echo "$fw,$rest" >> "$tmpfile"
    done
    mv "$tmpfile" "$RESULTS_FILE"
fi

# ─── Benchmark ───────────────────────────────────────
benchmark() {
    local name=$1
    local port=$(get_port "$name")
    local label=$(get_label "$name")
    local url="$HOST_PREFIX$name$HOST_SUFFIX:$port/$ENDPOINT"

    echo -e "${BOLD}▸ $label${NC} ${DIM}($name:$port)${NC}"

    # Benchmark runs
    echo -ne "  Benchmarking ×${RUNS}..."

    local total_rps=0 total_p50=0 total_p99=0

    for run in $(seq 1 $RUNS); do
        oha -n $REQUESTS -c $CONCURRENCY "$url" --no-tui > "/tmp/${name}_oha_${run}.txt" 2>&1

        local rps p50 p99
        rps=$(grep "Requests/sec" "/tmp/${name}_oha_${run}.txt" | awk '{print $2}')
        p50=$(grep "50.00%" "/tmp/${name}_oha_${run}.txt" | awk '{print $3}')
        p99=$(grep "99.00%" "/tmp/${name}_oha_${run}.txt" | awk '{print $3}')

        rps=${rps:-0}; p50=${p50:-0}; p99=${p99:-0}

        total_rps=$(echo "$total_rps + $rps" | bc)
        total_p50=$(echo "$total_p50 + $p50" | bc)
        total_p99=$(echo "$total_p99 + $p99" | bc)

        sleep 0.5
    done

    local avg_rps avg_p50 avg_p99
    avg_rps=$(printf "%.2f" "$(echo "scale=4; $total_rps / $RUNS" | bc)")
    avg_p50=$(printf "%.2f" "$(echo "scale=4; $total_p50 / $RUNS" | bc)")
    avg_p99=$(printf "%.2f" "$(echo "scale=4; $total_p99 / $RUNS" | bc)")

    echo -e " ${GREEN}✓${NC}"
    printf "  ${GREEN}→${NC} ${BOLD}%.0f req/s${NC} · p50: %sms · p99: %sms\n" \
        "$avg_rps" "$avg_p50" "$avg_p99"

    echo "$name,$avg_rps,$avg_p50,$avg_p99" >> "$RESULTS_FILE"
}

for fw in $FRAMEWORKS; do
    benchmark "$fw"
done

# ─── Generate bench.zon ─────────────────────────────

# docker compose down &>/dev/null (remove auto-down)

# ─── Summary ─────────────────────────────────────────
if [ "$QUIET" = false ]; then
    echo -e "${DIM}───────────────────────────────────────${NC}"
    printf "  ${BOLD}%-12s %9s %10s %10s${NC}\n" "Framework" "Req/s" "P50" "P99"

    tail -n +2 "$RESULTS_FILE" | while IFS=',' read -r fw rps p50 p99; do
        label=$(get_label "$fw")
        printf "  %-12s %9.0f %8.2f ms %8.2f ms\n" \
            "$label" "$rps" "$p50" "$p99"
    done

    echo -e "${DIM}───────────────────────────────────────${NC}"
    echo -e "  ${DIM}Saved: ${RESULTS_FILE}${NC}"
    echo -e "  ${DIM}${REQUESTS} req × ${CONCURRENCY} conn × ${RUNS} runs${NC}"
    echo ""
fi
