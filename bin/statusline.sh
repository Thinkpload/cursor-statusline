#!/usr/bin/env bash
set -uo pipefail

input=$(cat)

# ── Colors ────────────────────────────────────────────────────────────────────
RESET='\033[0m'
DIM='\033[90m'
BOLD='\033[1m'
BRIGHT='\033[93m'
CYAN='\033[36m'
BLUE='\033[34m'
BRIGHT_BLUE='\033[94m'
MAGENTA='\033[35m'
YELLOW='\033[33m'
GREEN='\033[32m'
RED='\033[31m'

color_for_pct() {
  local pct=${1:-0}
  pct=${pct%%.*}
  if [ "$pct" -ge 90 ]; then echo "$RED"
  elif [ "$pct" -ge 70 ]; then echo "$YELLOW"
  else echo "$GREEN"
  fi
}

progress_bar() {
  local pct=${1:-0} width=${2:-14}
  pct=${pct%%.*}
  [ "$pct" -lt 0 ] && pct=0
  [ "$pct" -gt 100 ] && pct=100
  local filled=$((pct * width / 100))
  local empty=$((width - filled))
  local bar=""
  [ "$filled" -gt 0 ] && printf -v fill "%${filled}s" && bar="${fill// /█}"
  [ "$empty" -gt 0 ] && printf -v pad "%${empty}s" && bar="${bar}${pad// /░}"
  echo "$bar"
}

fmt_tokens() {
  local n=${1:-0}
  [ -z "$n" ] || [ "$n" = "null" ] && { echo "0"; return; }
  if [ "$n" -ge 1000000 ]; then
    awk -v n="$n" 'BEGIN { printf "%.1fM", n/1000000 }'
  elif [ "$n" -ge 1000 ]; then
    awk -v n="$n" 'BEGIN { printf "%.1fk", n/1000 }'
  else
    echo "$n"
  fi
}

fmt_cents() {
  local cents=${1:-0}
  [ -z "$cents" ] || [ "$cents" = "null" ] && { echo '$0.00'; return; }
  awk -v c="$cents" 'BEGIN { printf "$%.2f", c/100 }'
}

fmt_duration() {
  local ms=${1:-0}
  [ -z "$ms" ] || [ "$ms" = "null" ] && return
  local sec=$((ms / 1000))
  local mins=$((sec / 60))
  local rem=$((sec % 60))
  if [ "$mins" -gt 0 ]; then echo "${mins}m ${rem}s"
  else echo "${sec}s"; fi
}

# ── Parse payload (context + session only — no plan fields here) ──────────────
MODEL=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
SESSION_ID=$(echo "$input" | jq -r '.session_id // "default"')
DIR=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
CTX_PCT=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
CTX_IN=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
CTX_OUT=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
CTX_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
SESSION_COST=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
SESSION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')
FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
SEVEN_D=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

BRANCH=""
if [ -n "$DIR" ] && git -C "$DIR" rev-parse --git-dir > /dev/null 2>&1; then
  BR=$(git -C "$DIR" branch --show-current 2>/dev/null)
  [ -n "$BR" ] && BRANCH=" | ${BR}"
fi

# ── Line 1: header ────────────────────────────────────────────────────────────
line1="${CYAN}[${MODEL}]${RESET} ${DIR##*/}${BRANCH}"
if [ -n "$SESSION_COST" ] && [ "$SESSION_COST" != "0" ]; then
  cost_fmt=$(awk -v c="$SESSION_COST" 'BEGIN { printf "$%.2f", c }')
  dur=$(fmt_duration "$SESSION_MS")
  line1="${line1}  ${DIM}session ${cost_fmt}${dur:+ · ${dur}}${RESET}"
fi
echo -e "$line1"

# ── Line 2: CTX — context window only ─────────────────────────────────────────
if [ -n "$CTX_PCT" ]; then
  ctx_int=${CTX_PCT%%.*}
  ctx_color=$(color_for_pct "$ctx_int")
  ctx_bar=$(progress_bar "$ctx_int")
  ctx_detail="$(fmt_tokens "$CTX_IN") in · $(fmt_tokens "$CTX_OUT") out"
  if [ -n "$CTX_SIZE" ] && [ "$CTX_SIZE" != "null" ]; then
    ctx_detail="${ctx_detail} · $(fmt_tokens "$CTX_SIZE") cap"
  fi
  echo -e "${CYAN}CTX ${RESET}${ctx_color}${ctx_bar}${RESET} ${ctx_int}%  ${DIM}${ctx_detail}${RESET}"
fi

# ── Line 3: PLAN — billing only (separate API, separate bar metric) ───────────
fetch_plan_usage() {
  local cache="${HOME}/.cursor/.statusline-plan-cache.json"
  local ttl=60

  if [ -f "$cache" ]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$ttl" ] && jq -e '.planUsage' "$cache" > /dev/null 2>&1; then
      cat "$cache"
      return 0
    fi
  fi

  local auth="${HOME}/.config/cursor/auth.json"
  [ ! -f "$auth" ] && return 1

  local token resp
  token=$(jq -r '.accessToken // empty' "$auth" 2>/dev/null) || return 1
  [ -z "$token" ] || [ "$token" = "null" ] && return 1

  resp=$(curl -sS -m 3 -X POST \
    'https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage' \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -H 'Connect-Protocol-Version: 1' \
    -d '{}' 2>/dev/null) || return 1

  echo "$resp" | jq -e '.planUsage' > /dev/null 2>&1 || return 1
  printf '%s' "$resp" > "$cache"
  echo "$resp"
}

plan_json=$(fetch_plan_usage 2>/dev/null || true)

if [ -n "$plan_json" ] && echo "$plan_json" | jq -e '.planUsage' > /dev/null 2>&1; then
  plan_pct=$(echo "$plan_json" | jq -r '.planUsage.totalPercentUsed // empty')
  incl_spend=$(echo "$plan_json" | jq -r '.planUsage.includedSpend // 0')
  incl_limit=$(echo "$plan_json" | jq -r '.planUsage.limit // 0')
  total_spend=$(echo "$plan_json" | jq -r '.planUsage.totalSpend // 0')
  bonus_spend=$(echo "$plan_json" | jq -r '.planUsage.bonusSpend // 0')

  # Bar matches Cursor UI ("22% of included total usage"), not inclSpend/limit
  if [ -z "$plan_pct" ] || [ "$plan_pct" = "null" ]; then
    if [ "$incl_limit" -gt 0 ] 2>/dev/null; then
      plan_pct=$(awk -v u="$incl_spend" -v l="$incl_limit" 'BEGIN { printf "%.1f", (u/l)*100 }')
    else
      plan_pct=0
    fi
  fi

  plan_int=$(awk -v p="$plan_pct" 'BEGIN {
    v = p + 0
    if (v < 0) v = 0
    if (v > 100) v = 100
    printf "%.0f", v
  }')

  plan_color=$(color_for_pct "$plan_int")
  plan_bar=$(progress_bar "$plan_int")
  plan_detail="total $(fmt_cents "$total_spend") · incl $(fmt_cents "$incl_spend")/$(fmt_cents "$incl_limit")"
  if [ "$bonus_spend" -gt 0 ] 2>/dev/null; then
    plan_detail="${plan_detail} · bonus $(fmt_cents "$bonus_spend")"
  fi

  echo -e "${MAGENTA}PLAN${RESET} ${plan_color}${plan_bar}${RESET} ${plan_int}%  ${DIM}${plan_detail}${RESET}"
fi

# ── Line 4: PWR — electricity (separate from CTX and PLAN) ───────────────────
# shellcheck disable=SC1091
source "${HOME}/.cursor/statusline-power.sh"
power_track "$SESSION_ID" 2>/dev/null || true

if [ -n "${PWR_NOW_W:-}" ]; then
  pwr_pct=$(awk -v w="$PWR_NOW_W" -v t="${PWR_TDP:-65}" 'BEGIN {
    p = (w / t) * 100
    if (p > 100) p = 100
    printf "%.0f", p
  }')
  pwr_color=$(color_for_pct "$pwr_pct")
  pwr_bar=$(progress_bar "$pwr_pct")
  pwr_wh_fmt=$(awk -v wh="${PWR_WH:-0}" 'BEGIN {
    if (wh >= 1) printf "%.2f Wh", wh
    else if (wh >= 0.001) printf "%.1f mWh", wh * 1000
    else printf "%.0f µWh", wh * 1000000
  }')
  pwr_now_dim="${DIM}${PWR_NOW_W}W now${RESET}"
  pwr_cost_part=""
  if [ -n "${PWR_COST:-}" ]; then
    pwr_cost_fmt=$(awk -v c="$PWR_COST" 'BEGIN { printf "$%.3f", c }')
    pwr_cost_part="  ${DIM}est ${pwr_cost_fmt}${RESET}"
  fi
  echo -e "${YELLOW}${BOLD}PWR${RESET}  ${BOLD}${BRIGHT}⚡ ${pwr_wh_fmt} session${RESET}  ${pwr_color}${pwr_bar}${RESET} ${pwr_pct}%  ${pwr_now_dim}${pwr_cost_part}  ${DIM}local PC${RESET}"
fi

# ── Line 5: SRV — cloud GPU (same layout as PWR: total + bar + current) ─────
# shellcheck disable=SC1091
source "${HOME}/.cursor/statusline-cloud.sh"
cloud_track "$SESSION_ID" "$input" 2>/dev/null || true

if [ -n "${CLOUD_NOW_W:-}" ] && [ "${CLOUD_SOURCE:-none}" != "none" ]; then
  srv_pct=$(awk -v w="$CLOUD_NOW_W" -v t="${CLOUD_TDP:-500}" 'BEGIN {
    p = (w / t) * 100
    if (p > 100) p = 100
    printf "%.0f", p
  }')
  srv_color=$(color_for_pct "$srv_pct")
  srv_bar=$(progress_bar "$srv_pct")
  srv_wh_fmt=$(cloud_fmt_wh "${CLOUD_WH:-0}")
  srv_now_dim="${DIM}${CLOUD_NOW_W}W now${RESET}"
  srv_tag="${DIM}${CLOUD_MODEL:-Composer} · ${CLOUD_GPU:-GPU}${RESET}"
  echo -e "${BLUE}${BOLD}SRV ${RESET} ${BOLD}${BRIGHT_BLUE}☁ ${srv_wh_fmt} session${RESET}  ${srv_color}${srv_bar}${RESET} ${srv_pct}%  ${srv_now_dim}  ${srv_tag}"
fi

# ── Line 6: rate limits (optional) ───────────────────────────────────────────
if [ -n "$FIVE_H" ] || [ -n "$SEVEN_D" ]; then
  parts=""
  if [ -n "$FIVE_H" ]; then
    fh=${FIVE_H%%.*}
    fh_color=$(color_for_pct "$fh")
    parts="${DIM}5h${RESET} ${fh_color}$(progress_bar "$fh" 8)${RESET} ${fh}%"
  fi
  if [ -n "$SEVEN_D" ]; then
    sd=${SEVEN_D%%.*}
    sd_color=$(color_for_pct "$sd")
    sd_part="${DIM}7d${RESET} ${sd_color}$(progress_bar "$sd" 8)${RESET} ${sd}%"
    parts="${parts:+${parts}   }${sd_part}"
  fi
  echo -e "$parts"
fi
