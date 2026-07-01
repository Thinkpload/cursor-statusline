#!/usr/bin/env bash
# Track session electricity from cursor-agent CPU usage + wall time.
# Usage: source and call: power_track <session_id>
# Sets: PWR_NOW_W, PWR_WH, PWR_COST, PWR_TDP

power_track() {
  local session_id=${1:-default}
  local conf="${HOME}/.cursor/statusline-power.conf"
  local tdp=65 idle=22 cores=4 rate=0
  if [ -f "$conf" ]; then
    # shellcheck disable=SC1090
    source "$conf"
    tdp=${TDP_WATTS:-65}
    idle=${IDLE_WATTS:-22}
    cores=${CORES:-4}
    rate=${ELECTRICITY_RATE:-0}
  fi

  local hz state_dir="${HOME}/.cursor"
  hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  mkdir -p "$state_dir"

  local state_file="${state_dir}/.statusline-power-${session_id}.json"
  local now cpu_jiffies agent_pids

  now=$(date +%s)
  cpu_jiffies=0
  agent_pids=$(pgrep -f 'cursor-agent|/\.local/bin/agent' 2>/dev/null || true)
  if [ -n "$agent_pids" ]; then
    local pid j
    for pid in $agent_pids; do
      j=$(awk '{print $14 + $15}' "/proc/${pid}/stat" 2>/dev/null) || continue
      cpu_jiffies=$((cpu_jiffies + j))
    done
  fi

  local use_system=0
  if [ "$cpu_jiffies" -eq 0 ]; then
    use_system=1
    cpu_jiffies=$(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8}' /proc/stat 2>/dev/null || echo 0)
  fi

  local start_wall=0 start_cpu=0 last_wall=0 last_cpu=0 accum_wh=0

  if [ -f "$state_file" ]; then
    start_wall=$(jq -r '.start_wall // 0' "$state_file" 2>/dev/null)
    start_cpu=$(jq -r '.start_cpu // 0' "$state_file" 2>/dev/null)
    last_wall=$(jq -r '.last_wall // 0' "$state_file" 2>/dev/null)
    last_cpu=$(jq -r '.last_cpu // 0' "$state_file" 2>/dev/null)
    accum_wh=$(jq -r '.accum_wh // 0' "$state_file" 2>/dev/null)
  fi

  if [ -z "$start_wall" ] || [ "$start_wall" = "0" ] || [ "$start_wall" = "null" ]; then
    start_wall=$now
    start_cpu=$cpu_jiffies
    last_wall=$now
    last_cpu=$cpu_jiffies
    accum_wh=0
  fi

  local delta_wall delta_cpu delta_cpu_sec util active_watts delta_wh

  delta_wall=$((now - last_wall))
  [ "$delta_wall" -lt 0 ] && delta_wall=0

  delta_cpu=$((cpu_jiffies - last_cpu))
  if [ "$delta_cpu" -lt 0 ]; then
    delta_cpu=0
    last_cpu=$cpu_jiffies
  fi

  delta_cpu_sec=$(awk -v d="$delta_cpu" -v h="$hz" 'BEGIN { printf "%.6f", d / h }')

  util=0
  if [ "$delta_wall" -gt 0 ]; then
    if [ "$use_system" -eq 1 ]; then
      util=$(awk -v c="$delta_cpu_sec" -v w="$delta_wall" -v n="$cores" 'BEGIN {
        u = c / (w * n)
        if (u < 0) u = 0
        if (u > 1) u = 1
        printf "%.4f", u
      }')
    else
      util=$(awk -v c="$delta_cpu_sec" -v w="$delta_wall" 'BEGIN {
        u = c / w
        if (u < 0) u = 0
        if (u > 1) u = 1
        printf "%.4f", u
      }')
    fi
  fi

  active_watts=$(awk -v idle="$idle" -v tdp="$tdp" -v u="$util" 'BEGIN {
    printf "%.1f", idle + (tdp - idle) * u
  }')

  if [ "$delta_wall" -gt 0 ]; then
    delta_wh=$(awk -v w="$active_watts" -v s="$delta_wall" 'BEGIN { printf "%.8f", w * s / 3600 }')
    accum_wh=$(awk -v a="$accum_wh" -v d="$delta_wh" 'BEGIN { printf "%.6f", a + d }')
  fi

  jq -n \
    --argjson start_wall "$start_wall" \
    --argjson start_cpu "$start_cpu" \
    --argjson last_wall "$now" \
    --argjson last_cpu "$cpu_jiffies" \
    --argjson accum_wh "$accum_wh" \
    --argjson use_system "$use_system" \
    '{start_wall:$start_wall,start_cpu:$start_cpu,last_wall:$last_wall,last_cpu:$last_cpu,accum_wh:$accum_wh,use_system:$use_system}' \
    > "$state_file" 2>/dev/null || true

  PWR_NOW_W=$active_watts
  PWR_WH=$accum_wh
  PWR_TDP=$tdp
  if awk -v r="$rate" 'BEGIN { exit (r > 0) ? 0 : 1 }'; then
    PWR_COST=$(awk -v wh="$accum_wh" -v r="$rate" 'BEGIN { printf "%.4f", (wh / 1000) * r }')
  else
    PWR_COST=""
  fi
}
