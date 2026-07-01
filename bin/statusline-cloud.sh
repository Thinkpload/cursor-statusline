#!/usr/bin/env bash
# Approximate Composer cloud GPU energy — mirrors local PWR tracking.
# Sets: CLOUD_WH, CLOUD_NOW_W, CLOUD_TDP, CLOUD_TOK_*, CLOUD_SOURCE, CLOUD_MODEL, CLOUD_GPU

cloud_apply_model_rates() {
  local payload=$1
  local model_id model_name param_summary

  model_id=$(echo "$payload" | jq -r '.model.id // ""' 2>/dev/null)
  model_name=$(echo "$payload" | jq -r '.model.display_name // "Unknown"' 2>/dev/null)
  param_summary=$(echo "$payload" | jq -r '.model.param_summary // ""' 2>/dev/null)

  CLOUD_MODEL=$model_name
  CLOUD_GPU="GPU"
  gpu_idle=${GPU_IDLE:-15}
  gpu_max=${GPU_MAX:-500}

  case "$model_id" in
    composer-2.5-fast|composer-2.5)
      if [[ "$model_id" == *fast* ]] || [[ "$param_summary" == *[Ff]ast* ]]; then
        wh_in=${COMPOSER_25_FAST_WH_IN:-22}
        wh_out=${COMPOSER_25_FAST_WH_OUT:-85}
        wh_cr=${COMPOSER_25_FAST_WH_CACHE_R:-2}
        wh_cw=${COMPOSER_25_FAST_WH_CACHE_W:-18}
        gpu_idle=${COMPOSER_25_FAST_GPU_IDLE:-12}
        gpu_max=${COMPOSER_25_FAST_GPU_MAX:-280}
      else
        wh_in=${COMPOSER_25_WH_IN:-32}
        wh_out=${COMPOSER_25_WH_OUT:-115}
        wh_cr=${COMPOSER_25_WH_CACHE_R:-3}
        wh_cw=${COMPOSER_25_WH_CACHE_W:-25}
        gpu_idle=${COMPOSER_25_GPU_IDLE:-18}
        gpu_max=${COMPOSER_25_GPU_MAX:-450}
      fi
      ;;
    composer-2*|composer-1*|composer-*)
      wh_in=${COMPOSER_2_WH_IN:-45}
      wh_out=${COMPOSER_2_WH_OUT:-165}
      wh_cr=${COMPOSER_2_WH_CACHE_R:-4}
      wh_cw=${COMPOSER_2_WH_CACHE_W:-35}
      gpu_idle=${COMPOSER_2_GPU_IDLE:-25}
      gpu_max=${COMPOSER_2_GPU_MAX:-700}
      ;;
    *)
      wh_in=${WH_PER_1M_INPUT:-40}
      wh_out=${WH_PER_1M_OUTPUT:-150}
      wh_cr=${WH_PER_1M_CACHE_READ:-3}
      wh_cw=${WH_PER_1M_CACHE_WRITE:-30}
      gpu_idle=${GPU_IDLE:-15}
      gpu_max=${GPU_MAX:-500}
      CLOUD_GPU="cloud"
      ;;
  esac
}

cloud_token_wh() {
  awk -v i="${1:-0}" -v o="${2:-0}" -v cr="${3:-0}" -v cw="${4:-0}" \
    -v ri="$wh_in" -v ro="$wh_out" -v rcr="$wh_cr" -v rcw="$wh_cw" 'BEGIN {
      printf "%.8f", (i/1000000)*ri + (o/1000000)*ro + (cr/1000000)*rcr + (cw/1000000)*rcw
    }'
}

cloud_track() {
  local session_id=${1:-default}
  local payload=${2:-'{}'}
  local conf="${HOME}/.cursor/statusline-cloud.conf"
  local wh_in=40 wh_out=150 wh_cr=3 wh_cw=30 gpu_idle=15 gpu_max=500
  local interval_wh=0

  CLOUD_MODEL=""
  CLOUD_GPU=""
  CLOUD_SOURCE="none"

  if [ -f "$conf" ]; then
    # shellcheck disable=SC1090
    source "$conf"
  fi

  cloud_apply_model_rates "$payload"

  local state_dir="${HOME}/.cursor"
  local state_file="${state_dir}/.statusline-cloud-${session_id}.json"
  mkdir -p "$state_dir"

  local now last_wall=0 last_sig="" last_usage_num=0
  local last_in=0 last_out=0 last_cr=0 last_cw=0 accum_wh=0
  local last_ctx_in=0 last_ctx_out=0
  local cum_in=0 cum_out=0 cum_cache_r=0 cum_cache_w=0
  local got_usage=0

  now=$(date +%s)

  if [ -f "$state_file" ]; then
    last_wall=$(jq -r '.last_wall // 0' "$state_file" 2>/dev/null)
    last_sig=$(jq -r '.last_sig // ""' "$state_file" 2>/dev/null)
    last_usage_num=$(jq -r '.last_usage_num // 0' "$state_file" 2>/dev/null)
    last_in=$(jq -r '.cum_in // 0' "$state_file" 2>/dev/null)
    last_out=$(jq -r '.cum_out // 0' "$state_file" 2>/dev/null)
    last_cr=$(jq -r '.cum_cache_r // 0' "$state_file" 2>/dev/null)
    last_cw=$(jq -r '.cum_cache_w // 0' "$state_file" 2>/dev/null)
    last_ctx_in=$(jq -r '.payload_ctx_in // 0' "$state_file" 2>/dev/null)
    last_ctx_out=$(jq -r '.payload_ctx_out // 0' "$state_file" 2>/dev/null)
    accum_wh=$(jq -r '.accum_wh // 0' "$state_file" 2>/dev/null)
    cum_in=$last_in
    cum_out=$last_out
    cum_cache_r=$last_cr
    cum_cache_w=$last_cw
  fi

  if [ -z "$last_wall" ] || [ "$last_wall" = "0" ] || [ "$last_wall" = "null" ]; then
    last_wall=$now
  fi

  local usage_type usage_sig payload_out payload_ctx_in payload_ctx_out
  usage_type=$(echo "$payload" | jq -r '.context_window.current_usage | type' 2>/dev/null)
  [ -z "$usage_type" ] || [ "$usage_type" = "null" ] && usage_type="null"
  payload_out=$(echo "$payload" | jq -r '.context_window.total_output_tokens // empty' 2>/dev/null)
  payload_ctx_in=$(echo "$payload" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null)
  payload_ctx_out=$(echo "$payload" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null)

  if [ "$usage_type" = "object" ]; then
    usage_sig=$(echo "$payload" | jq -c '.context_window.current_usage' 2>/dev/null || echo "")
    if [ -n "$usage_sig" ] && [ "$usage_sig" != "null" ] && [ "$usage_sig" != "$last_sig" ]; then
      local add_in add_out add_cr add_cw
      add_in=$(echo "$payload" | jq -r '.context_window.current_usage.input_tokens // 0')
      add_out=$(echo "$payload" | jq -r '.context_window.current_usage.output_tokens // 0')
      add_cr=$(echo "$payload" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
      add_cw=$(echo "$payload" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
      cum_in=$((cum_in + add_in + add_cr + add_cw))
      cum_out=$((cum_out + add_out))
      cum_cache_r=$((cum_cache_r + add_cr))
      cum_cache_w=$((cum_cache_w + add_cw))
      last_sig=$usage_sig
      got_usage=1
    fi
  elif [ "$usage_type" = "number" ]; then
    local curr_n delta
    curr_n=$(echo "$payload" | jq -r '.context_window.current_usage')
    delta=$((curr_n - last_usage_num))
    if [ "$delta" -gt 0 ]; then
      cum_in=$((cum_in + delta))
      got_usage=1
    fi
    last_usage_num=$curr_n
  fi

  if [ -n "$payload_out" ] && [ "$payload_out" != "null" ]; then
    if [ "$payload_out" -gt "$cum_out" ] 2>/dev/null; then
      cum_out=$payload_out
      got_usage=1
    fi
  fi

  # Fallback before current_usage exists (common in first session turn)
  if [ "$got_usage" -eq 0 ]; then
    local dctx_in dctx_out
    dctx_in=$((payload_ctx_in - last_ctx_in))
    dctx_out=$((payload_ctx_out - last_ctx_out))
    [ "$dctx_in" -lt 0 ] && dctx_in=0
    [ "$dctx_out" -lt 0 ] && dctx_out=0
    if [ "$dctx_in" -gt 0 ] || [ "$dctx_out" -gt 0 ]; then
      cum_in=$((cum_in + dctx_in))
      cum_out=$((cum_out + dctx_out))
      got_usage=1
    fi
  fi

  local delta_wall delta_in delta_out delta_cr delta_cw active_watts
  delta_wall=$((now - last_wall))
  [ "$delta_wall" -lt 0 ] && delta_wall=0

  delta_in=$((cum_in - last_in))
  [ "$delta_in" -lt 0 ] && delta_in=0
  delta_out=$((cum_out - last_out))
  [ "$delta_out" -lt 0 ] && delta_out=0
  delta_cr=$((cum_cache_r - last_cr))
  [ "$delta_cr" -lt 0 ] && delta_cr=0
  delta_cw=$((cum_cache_w - last_cw))
  [ "$delta_cw" -lt 0 ] && delta_cw=0

  local total_tok=$((cum_in + cum_out))

  if [ "$delta_in" -gt 0 ] || [ "$delta_out" -gt 0 ] || [ "$delta_cr" -gt 0 ] || [ "$delta_cw" -gt 0 ]; then
    interval_wh=$(cloud_token_wh "$delta_in" "$delta_out" "$delta_cr" "$delta_cw")
    accum_wh=$(awk -v a="$accum_wh" -v d="$interval_wh" 'BEGIN { printf "%.6f", a + d }')
    CLOUD_SOURCE="tokens"
  else
    local session_cost
    session_cost=$(echo "$payload" | jq -r '.cost.total_cost_usd // empty' 2>/dev/null)
    if [ -n "$session_cost" ] && [ "$session_cost" != "0" ] && [ "$session_cost" != "null" ]; then
      accum_wh=$(awk -v c="$session_cost" -v r="${WH_PER_DOLLAR:-35}" 'BEGIN { printf "%.6f", c * r }')
      CLOUD_SOURCE="cost"
    elif [ -n "$CLOUD_MODEL" ] && [ "$CLOUD_MODEL" != "Unknown" ]; then
      CLOUD_SOURCE="idle"
    fi
  fi

  if [ "$delta_wall" -le 0 ] && awk -v d="${interval_wh:-0}" 'BEGIN { exit (d > 0) ? 0 : 1 }' 2>/dev/null; then
    delta_wall=1
  fi

  if [ "$delta_wall" -gt 0 ] && awk -v d="${interval_wh:-0}" 'BEGIN { exit (d > 0) ? 0 : 1 }' 2>/dev/null; then
    active_watts=$(awk -v wh="${interval_wh:-0}" -v s="$delta_wall" 'BEGIN {
      w = wh / (s / 3600)
      printf "%.1f", w
    }')
  else
    active_watts=$gpu_idle
  fi

  active_watts=$(awk -v w="$active_watts" -v m="$gpu_max" 'BEGIN {
    if (w > m) w = m
    if (w < 0) w = 0
    printf "%.1f", w
  }')

  jq -n \
    --argjson last_wall "$now" \
    --arg last_sig "${last_sig:-}" \
    --argjson last_usage_num "${last_usage_num:-0}" \
    --argjson cum_in "$cum_in" \
    --argjson cum_out "$cum_out" \
    --argjson cum_cache_r "$cum_cache_r" \
    --argjson cum_cache_w "$cum_cache_w" \
    --argjson accum_wh "$accum_wh" \
    --argjson payload_ctx_in "${payload_ctx_in:-0}" \
    --argjson payload_ctx_out "${payload_ctx_out:-0}" \
    --arg model "${CLOUD_MODEL:-}" \
    '{last_wall:$last_wall,last_sig:$last_sig,last_usage_num:$last_usage_num,cum_in:$cum_in,cum_out:$cum_out,cum_cache_r:$cum_cache_r,cum_cache_w:$cum_cache_w,accum_wh:$accum_wh,payload_ctx_in:$payload_ctx_in,payload_ctx_out:$payload_ctx_out,model:$model}' \
    > "$state_file" 2>/dev/null || true

  CLOUD_WH=$accum_wh
  CLOUD_NOW_W=$active_watts
  CLOUD_TDP=$gpu_max
  CLOUD_TOK_IN=$cum_in
  CLOUD_TOK_OUT=$cum_out
  CLOUD_TOK_TOTAL=$total_tok
}

cloud_fmt_wh() {
  awk -v wh="${1:-0}" 'BEGIN {
    if (wh >= 1) printf "~%.2f Wh", wh
    else if (wh >= 0.001) printf "~%.1f mWh", wh * 1000
    else printf "~%.0f µWh", wh * 1000000
  }'
}

cloud_fmt_tokens() {
  local n=${1:-0}
  if [ "$n" -ge 1000000 ]; then awk -v n="$n" 'BEGIN { printf "%.1fM", n/1000000 }'
  elif [ "$n" -ge 1000 ]; then awk -v n="$n" 'BEGIN { printf "%.1fk", n/1000 }'
  else echo "$n"; fi
}
