#!/bin/bash
# bench.sh: Orchestrates container lifecycle, memory measurement, and benchmarking from the host.
# Usage: ./bench.sh [ziex|leptos|solidjs|nextjs|all]


set -euo pipefail

ALL_FRAMEWORKS=(ziex jetzig leptos dioxus solidjs nextjs)
RESULTS_FILE="result.csv"
BENCH_CONTAINER="ziex_bench-bench-1"

if [ $# -gt 0 ]; then
  FRAMEWORKS=("$@")
else
  FRAMEWORKS=("${ALL_FRAMEWORKS[@]}")
fi


get_label() {
  case "$1" in
    ziex) echo "Ziex" ;;
    jetzig) echo "Jetzig" ;;
    leptos) echo "Leptos" ;;
    dioxus) echo "Dioxus" ;;
    solidjs) echo "SolidStart" ;;
    nextjs) echo "Next.js" ;;
    *) echo "$1" ;;
  esac
}

# Helper: current time in milliseconds (cross-platform, no lang deps)
ms_now() {
  if command -v gdate &>/dev/null; then
    echo $(($(gdate +%s%N)/1000000))
  elif [[ "$OSTYPE" != "darwin"* ]]; then
    echo $(($(date +%s%N)/1000000))
  else
    # macOS without gdate: second precision only
    echo $(($(date +%s) * 1000))
  fi
}

echo "framework,idle_mb,peak_mb,build_time_s,image_mb,cold_start_ms,cpu_peak_pct,rps,p50_ms,p99_ms" > "$RESULTS_FILE"


# Build
# Build each framework individually using BuildKit (--progress=plain) so we can
# extract the actual build duration from its output. BuildKit emits lines like:
#   #N DONE 45.2s
# The maximum DONE timestamp across all steps = wall-clock build time.
# Image size is captured immediately after build via docker image inspect.
echo "Building containers..."
BUILD_TIME_LIST=()
IMAGE_MB_LIST=()
for fw in "${FRAMEWORKS[@]}"; do
  echo -n "  Building $fw..."
  if [ "$fw" = "ziex" ]; then
    build_output=$(DOCKER_BUILDKIT=1 docker compose build "$fw" bench --progress=plain 2>&1)
  else
    build_output=$(DOCKER_BUILDKIT=1 docker compose build "$fw" --progress=plain 2>&1)
  fi

  # Max DONE timestamp from BuildKit plain output = total wall-clock build time
  build_elapsed=$(echo "$build_output" | awk '
    /^#[0-9]+ DONE / {
      val = $3; sub(/s$/, "", val)
      if (val + 0 > max) max = val + 0
    }
    END { printf "%.0f", max }
  ')
  build_elapsed=${build_elapsed:-0}
  BUILD_TIME_LIST+=("$build_elapsed")

  # Image size: docker compose names images as <project>-<service> (project = ziex_bench)
  img_bytes=$(docker image inspect "ziex_bench-$fw" --format '{{.Size}}' 2>/dev/null || echo 0)
  img_mb=$(awk "BEGIN {printf \"%.0f\", $img_bytes / 1048576}")
  IMAGE_MB_LIST+=("${img_mb:-0}")

  echo " done (${build_elapsed}s, ${img_mb} MB)"
done


# ─── Start containers ─────────────────────────────────────────────────────────
echo "Starting containers..."
docker compose up -d --wait "${FRAMEWORKS[@]}" bench


# Print a DIM line to separate startup logs from benchmark output
echo -e "\033[2m───────────────────────────────────────────────────────────────────────\033[0m"


IDLE_MEM_LIST=()
echo "▸ Measuring idle memory..."
for fw in "${FRAMEWORKS[@]}"; do
  cid=$(docker compose ps -q "$fw")
  if [ -z "$cid" ]; then
    echo "  $fw: container not found" >&2
    IDLE_MEM_LIST+=("0")
    continue
  fi
  idle_mem=$(docker stats --no-stream --format "{{.MemUsage}}" "$cid" | awk -F'/' '{print $1}' | grep -o '[0-9.]*' | head -1)
  IDLE_MEM_LIST+=("${idle_mem:-0}")
done
echo ""


# Benchmark (req/s + peak memory + peak CPU)
# CPU is sampled in a background loop during the oha run. docker stats --no-stream
# takes ~1 s per call (one Docker metrics interval), so we get several samples
# over a typical 10 k-request run. The peak is recorded.
echo "▸ Measuring req/s + CPU..."
PEAK_MEM_LIST=()
CPU_PEAK_LIST=()
BENCH_RESULTS_LIST=()

for fw in "${FRAMEWORKS[@]}"; do
  cid=$(docker compose ps -q "$fw")

  # Start background CPU sampling loop
  CPU_TMP=$(mktemp)
  (
    while true; do
      docker stats --no-stream --format "{{.CPUPerc}}" "$cid" 2>/dev/null \
        | tr -d '%' >> "$CPU_TMP"
      sleep 0.3
    done
  ) &
  CPU_LOOP_PID=$!

  # Run benchmark for this single framework
  docker exec -t "$BENCH_CONTAINER" /bench/oha.sh --container --quiet "$fw" 2>&1 | \
    awk 'NR>=4 && NR<=8 {print; fflush()}'
  echo ""

  # Stop CPU sampling
  kill "$CPU_LOOP_PID" 2>/dev/null; wait "$CPU_LOOP_PID" 2>/dev/null || true
  peak_cpu=$(sort -rn "$CPU_TMP" 2>/dev/null | head -1 | grep -o '[0-9.]*' || echo 0)
  peak_cpu=${peak_cpu:-0}
  rm -f "$CPU_TMP"
  CPU_PEAK_LIST+=("$peak_cpu")

  # Measure peak memory immediately after benchmark (memory still elevated)
  if [ -n "$cid" ]; then
    peak_mem=$(docker stats --no-stream --format "{{.MemUsage}}" "$cid" | awk -F'/' '{print $1}' | grep -o '[0-9.]*' | head -1)
    PEAK_MEM_LIST+=("${peak_mem:-0}")
  else
    PEAK_MEM_LIST+=("0")
  fi

  # Extract benchmark result for this framework
  docker cp "$BENCH_CONTAINER:/bench/result.csv" /tmp/bench_result_${fw}.csv 2>/dev/null
  result_line=$(tail -1 /tmp/bench_result_${fw}.csv)
  BENCH_RESULTS_LIST+=("$result_line")
done


# Cold start
# For each framework: stop container → record time → start container → poll
# from inside the bench container (which shares bench-net) until the /ssr
# endpoint responds. Time from stop to first successful response = cold start.
echo "▸ Measuring cold start..."
COLD_START_LIST=()
for fw in "${FRAMEWORKS[@]}"; do
  echo -n "  $fw..."
  docker compose stop "$fw" > /dev/null 2>&1

  t0=$(ms_now)
  docker compose start "$fw" > /dev/null 2>&1

  # Poll the /ssr endpoint from inside bench container (shares bench-net)
  until docker exec "$BENCH_CONTAINER" curl -sf "http://$fw:3000/ssr" > /dev/null 2>&1; do
    sleep 0.05
  done
  cold_ms=$(( $(ms_now) - t0 ))

  COLD_START_LIST+=("$cold_ms")
  echo " ${cold_ms}ms"
done
echo ""


# Write combined results
for i in "${!FRAMEWORKS[@]}"; do
  fw="${FRAMEWORKS[$i]}"
  idle="${IDLE_MEM_LIST[$i]:-0}"
  peak="${PEAK_MEM_LIST[$i]:-0}"
  build_time="${BUILD_TIME_LIST[$i]:-0}"
  img_mb="${IMAGE_MB_LIST[$i]:-0}"
  cold_ms="${COLD_START_LIST[$i]:-0}"
  cpu_peak="${CPU_PEAK_LIST[$i]:-0}"
  IFS=',' read -r _ rps p50 p99 <<< "${BENCH_RESULTS_LIST[$i]}"
  echo "$fw,$idle,$peak,$build_time,$img_mb,$cold_ms,$cpu_peak,$rps,$p50,$p99" >> "$RESULTS_FILE"
done

# Stop all services
docker compose stop "${FRAMEWORKS[@]}" > /dev/null 2>&1

# Pretty summary output from 
echo -e "\033[2m───────────────────────────────────────────────────────────────────────\033[0m"
echo ""
printf '%-12s %9s %10s %10s %9s %9s %8s %8s %10s %10s\n' \
  "Framework" "Req/s" "P50" "P99" "Idle" "Peak" "Image" "Cold" "CPU%" "Build"
tail -n +2 "$RESULTS_FILE" | while IFS=',' read -r fw idle peak build_time img_mb cold_ms cpu_peak rps p50 p99; do
  label=$(get_label "$fw")
  printf '  %-12s %9.0f %8.2f ms %8.2f ms %6s MB %6s MB %6s MB %6sms %8s%% %8ss\n' \
    "$label" "$rps" "$p50" "$p99" "$idle" "$peak" "$img_mb" "$cold_ms" "$cpu_peak" "$build_time"
done

echo ""
echo -e "\033[2mResults written to: $RESULTS_FILE\033[0m"

# Generate bench.zon from results
ZON_FILE="../site/pages/bench.zon"
{
  echo "// Auto-generated by bench/bench.sh — do not edit"
  echo ".{"
  tail -n +2 "$RESULTS_FILE" | while IFS=',' read -r fw idle peak build_time img_mb cold_ms cpu_peak rps p50 p99; do
    label=$(get_label "$fw")
    cat <<EOF
    .{
        .id = "$fw",
        .label = "$label",
        .idle_memory_mb = $idle,
        .peak_memory_mb = $peak,
        .build_time_s = $build_time,
        .image_mb = $img_mb,
        .cold_start_ms = $cold_ms,
        .cpu_peak_pct = $cpu_peak,
        .requests_per_sec = ${rps%.*},
        .p50_latency_ms = $p50,
        .p99_latency_ms = $p99,
    },
EOF
  done
  echo "}"
} > "$ZON_FILE"
echo -e "\033[2mbench.zon written to $ZON_FILE\033[0m"
