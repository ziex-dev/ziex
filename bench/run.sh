#!/bin/bash
# bench.sh: Orchestrates container lifecycle, memory measurement, and benchmarking from the host.
# Usage: ./bench.sh [ziex|leptos|solidjs|nextjs|all]


set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALL_FRAMEWORKS=(ziex jetzig leptos dioxus solidjs nextjs)
RESULTS_FILE="result.csv"
BENCH_CONTAINER="ziex_bench-bench-1"
BENCHFIG="$SCRIPT_DIR/../site/app/pages/benchfig.zon"

# Read a required field from the flat benchfig.zon (.field = value).
zon_field() {
  local key="$1" val
  val=$(grep -oE "\.$key[[:space:]]*=[[:space:]]*[^,]+" "$BENCHFIG" \
    | head -1 | sed -E "s/.*=[[:space:]]*//; s/^\"//; s/\"$//; s/[[:space:]]*$//")
  [ -n "$val" ] || { echo "error: missing required field '.$key' in $BENCHFIG" >&2; exit 1; }
  echo "$val"
}

[ -f "$BENCHFIG" ] || { echo "error: benchfig.zon not found at $BENCHFIG" >&2; exit 1; }
REQUESTS=$(zon_field requests)
CONCURRENCY=$(zon_field concurrency)
RUNS=$(zon_field runs)
ENDPOINT=$(zon_field endpoint)

# Servers are pinned to cores 0,1; give the load generator every remaining core.
DOCKER_NCPU=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 4)
if [ "$DOCKER_NCPU" -gt 2 ]; then
  export BENCH_CPUSET="2-$((DOCKER_NCPU - 1))"
else
  echo "warning: only $DOCKER_NCPU CPUs available, load generator will share cores with servers" >&2
  export BENCH_CPUSET="0-$((DOCKER_NCPU - 1))"
fi

MEASURE_BUILD_TIME=false
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--build-time" ]; then
    MEASURE_BUILD_TIME=true
  else
    ARGS+=("$arg")
  fi
done

if [ ${#ARGS[@]} -gt 0 ]; then
  FRAMEWORKS=("${ARGS[@]}")
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

# Helper: read cgroup memory value (bytes → MB) from inside container
# Uses cgroup v2 (memory.current / memory.peak) with v1 fallback
cgroup_mem_current_mb() {
  local cid="$1"
  local bytes
  bytes=$(docker exec "$cid" cat /sys/fs/cgroup/memory.current 2>/dev/null \
    || docker exec "$cid" cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null \
    || echo 0)
  awk "BEGIN {printf \"%.1f\", $bytes / 1048576}"
}

cgroup_mem_peak_mb() {
  local cid="$1"
  local bytes
  bytes=$(docker exec "$cid" cat /sys/fs/cgroup/memory.peak 2>/dev/null \
    || docker exec "$cid" cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes 2>/dev/null \
    || echo 0)
  awk "BEGIN {printf \"%.1f\", $bytes / 1048576}"
}

# Helper: reset cgroup peak memory counter before benchmark
cgroup_mem_peak_reset() {
  local cid="$1"
  docker exec "$cid" sh -c 'echo 0 > /sys/fs/cgroup/memory.peak' 2>/dev/null \
    || docker exec "$cid" sh -c 'echo 0 > /sys/fs/cgroup/memory/memory.max_usage_in_bytes' 2>/dev/null \
    || true
}

# Helper: read cgroup CPU usage in microseconds (cgroup v2) or nanoseconds (v1→converted)
cgroup_cpu_usage_us() {
  local cid="$1"
  local val
  # cgroup v2: cpu.stat has "usage_usec <value>"
  val=$(docker exec "$cid" sh -c 'grep "^usage_usec" /sys/fs/cgroup/cpu.stat 2>/dev/null | awk "{print \$2}"' 2>/dev/null || true)
  if [ -n "$val" ] && [ "$val" != "0" ]; then
    echo "$val"
    return
  fi
  # cgroup v1 fallback: cpuacct.usage is in nanoseconds → convert to microseconds
  val=$(docker exec "$cid" cat /sys/fs/cgroup/cpuacct/cpuacct.usage 2>/dev/null || echo 0)
  awk "BEGIN {printf \"%.0f\", $val / 1000}"
}

# Helper: get binary size in MB for compiled frameworks
get_binary_size_mb() {
  local cid="$1"
  local fw="$2"
  local bin_path
  case "$fw" in
    ziex)    bin_path="/app/ziex_app" ;;
    jetzig)  bin_path="/app/jetzig-demo" ;;
    leptos)  bin_path="/app/leptos-ssr" ;;
    dioxus)  bin_path="/app/server" ;;
    *)       echo "0"; return ;;
  esac
  local bytes
  bytes=$(docker exec "$cid" stat -c '%s' "$bin_path" 2>/dev/null \
    || docker exec "$cid" stat -f '%z' "$bin_path" 2>/dev/null \
    || echo 0)
  awk "BEGIN {printf \"%.1f\", $bytes / 1048576}"
}

echo "framework,idle_mb,peak_mb,build_time_s,image_mb,binary_mb,cold_start_ms,cpu_avg_pct,cpu_peak_pct,rps,p50_ms,p99_ms" > "$RESULTS_FILE"


# ─── Config (from benchfig.zon) ───────────────────────────────────────────────
echo -e "\033[1mBenchmark config\033[0m \033[2m($BENCHFIG)\033[0m"
echo "  endpoint    : /$ENDPOINT"
echo "  requests    : $REQUESTS"
echo "  concurrency : $CONCURRENCY"
echo "  runs        : $RUNS"
echo "  frameworks  : ${FRAMEWORKS[*]}"
echo ""


# Build
echo "Building containers..."
BUILD_TIME_LIST=()
IMAGE_MB_LIST=()
docker compose build bench > /dev/null 2>&1
for fw in "${FRAMEWORKS[@]}"; do
  echo -n "  Building $fw..."
  if [ "$MEASURE_BUILD_TIME" = true ]; then
    # Build each framework individually using BuildKit (--progress=plain) so we can
    # extract the actual build duration from its output. BuildKit emits lines like:
    #   #N DONE 45.2s
    # The maximum DONE timestamp across all steps = wall-clock build time.
    if [ "$fw" = "ziex" ]; then
      build_output=$(DOCKER_BUILDKIT=1 docker compose --progress=plain build "$fw" bench)
    else
      build_output=$(DOCKER_BUILDKIT=1 docker compose --progress=plain build "$fw")
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
  else
    # docker compose build "$fw" > /dev/null 2>&1
    docker compose build bench > /dev/null 2>&1
    build_elapsed=0
  fi
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
echo "▸ Measuring idle memory (cgroup)..."
for fw in "${FRAMEWORKS[@]}"; do
  cid=$(docker compose ps -q "$fw")
  if [ -z "$cid" ]; then
    echo "  $fw: container not found" >&2
    IDLE_MEM_LIST+=("0")
    continue
  fi
  idle_mem=$(cgroup_mem_current_mb "$cid")
  IDLE_MEM_LIST+=("${idle_mem:-0}")
  echo "  $fw: ${idle_mem} MB"
done
echo ""


# Binary size (only meaningful for compiled frameworks)
echo "▸ Measuring binary size..."
BINARY_MB_LIST=()
for fw in "${FRAMEWORKS[@]}"; do
  cid=$(docker compose ps -q "$fw")
  if [ -z "$cid" ]; then
    BINARY_MB_LIST+=("0")
    continue
  fi
  bin_mb=$(get_binary_size_mb "$cid" "$fw")
  BINARY_MB_LIST+=("${bin_mb:-0}")
  echo "  $fw: ${bin_mb} MB"
done
echo ""


# Benchmark (req/s + peak memory + CPU via cgroup cpu.stat)
# Average CPU = delta(usage_usec) / (wall_time_us * num_cpus) * 100
# Peak CPU = max sampled delta(usage_usec) over short intervals during the benchmark
echo "▸ Measuring req/s + CPU..."
PEAK_MEM_LIST=()
CPU_AVG_LIST=()
CPU_PEAK_LIST=()
BENCH_RESULTS_LIST=()

# Number of CPUs allocated to containers (from compose resource limits)
NUM_CPUS=2

for fw in "${FRAMEWORKS[@]}"; do
  cid=$(docker compose ps -q "$fw")

  # Reset cgroup peak counter before benchmark so we get true peak during the run
  cgroup_mem_peak_reset "$cid"

  # Record CPU usage before benchmark (cgroup cpu.stat)
  cpu_before=$(cgroup_cpu_usage_us "$cid")
  wall_before=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))

  # Start background CPU peak sampling loop via cgroup cpu.stat
  CPU_PEAK_TMP=$(mktemp)
  (
    prev_cpu=$(cgroup_cpu_usage_us "$cid")
    prev_wall=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))
    while true; do
      sleep 0.2
      cur_cpu=$(cgroup_cpu_usage_us "$cid")
      cur_wall=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))
      awk "BEGIN {
        delta_cpu = $cur_cpu - $prev_cpu;
        wall_us = ($cur_wall - $prev_wall) / 1000;
        if (wall_us > 0) printf \"%.1f\\n\", (delta_cpu / (wall_us * $NUM_CPUS)) * 100;
      }" >> "$CPU_PEAK_TMP"
      prev_cpu=$cur_cpu
      prev_wall=$cur_wall
    done
  ) &
  CPU_PEAK_PID=$!

  # Run benchmark for this single framework
  docker exec -t "$BENCH_CONTAINER" /bench/oha.sh --container --quiet "$fw" 2>&1 | \
    awk 'NR>=4 && NR<=8 {print; fflush()}'
  echo ""

  # Record CPU usage after benchmark
  cpu_after=$(cgroup_cpu_usage_us "$cid")
  wall_after=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))

  # Stop CPU peak sampling
  kill "$CPU_PEAK_PID" 2>/dev/null; wait "$CPU_PEAK_PID" 2>/dev/null || true
  peak_cpu=$(sort -rn "$CPU_PEAK_TMP" 2>/dev/null | head -1 | grep -o '[0-9.]*' || echo 0)
  peak_cpu=${peak_cpu:-0}
  rm -f "$CPU_PEAK_TMP"
  CPU_PEAK_LIST+=("$peak_cpu")

  # Compute average CPU% = delta_cpu_us / (wall_time_us * num_cpus) * 100
  cpu_avg=$(awk "BEGIN {
    delta_cpu = $cpu_after - $cpu_before;
    wall_us = ($wall_after - $wall_before) / 1000;
    if (wall_us > 0) printf \"%.1f\", (delta_cpu / (wall_us * $NUM_CPUS)) * 100;
    else printf \"0\";
  }")
  CPU_AVG_LIST+=("${cpu_avg:-0}")

  # Read true peak memory from cgroup (kernel-tracked, no sampling needed)
  if [ -n "$cid" ]; then
    peak_mem=$(cgroup_mem_peak_mb "$cid")
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
  bin_mb="${BINARY_MB_LIST[$i]:-0}"
  cold_ms="${COLD_START_LIST[$i]:-0}"
  cpu_avg="${CPU_AVG_LIST[$i]:-0}"
  cpu_peak="${CPU_PEAK_LIST[$i]:-0}"
  IFS=',' read -r _ rps p50 p99 <<< "${BENCH_RESULTS_LIST[$i]}"
  echo "$fw,$idle,$peak,$build_time,$img_mb,$bin_mb,$cold_ms,$cpu_avg,$cpu_peak,$rps,$p50,$p99" >> "$RESULTS_FILE"
done

# Stop all services
docker compose stop "${FRAMEWORKS[@]}" > /dev/null 2>&1

# Pretty summary output from 
echo -e "\033[2m───────────────────────────────────────────────────────────────────────\033[0m"
echo ""
printf '%-12s %9s %10s %10s %9s %9s %8s %8s %8s %8s %8s %10s\n' \
  "Framework" "Req/s" "P50" "P99" "Idle" "Peak" "Image" "Binary" "Cold" "AvgCPU" "PkCPU" "Build"
tail -n +2 "$RESULTS_FILE" | while IFS=',' read -r fw idle peak build_time img_mb bin_mb cold_ms cpu_avg cpu_peak rps p50 p99; do
  label=$(get_label "$fw")
  printf '  %-12s %9.0f %8.2f ms %8.2f ms %6s MB %6s MB %6s MB %5s MB %6sms %6s%% %6s%% %8ss\n' \
    "$label" "$rps" "$p50" "$p99" "$idle" "$peak" "$img_mb" "$bin_mb" "$cold_ms" "$cpu_avg" "$cpu_peak" "$build_time"
done

echo ""
echo -e "\033[2mResults written to: $RESULTS_FILE\033[0m"