#!/usr/bin/env bash
# =============================================================================
# llm-ctl — Local LLM Manager for Claude Code
# =============================================================================
# Works with both zsh and bash 4+ on macOS, Linux, and WSL.
#
# Setup:
#   1. Place this file somewhere (e.g. ~/llm-ctl.sh)
#   2. Source it from your shell rc file:
#        # For zsh  — add to ~/.zshrc:
#        source ~/llm-ctl.sh
#        # For bash — add to ~/.bashrc:
#        source ~/llm-ctl.sh
#   3. Reload your shell: exec $SHELL
#
# Requirements:
#   - bash 4+ OR zsh 5+
#   - llama-server (from llama.cpp) — see LLM_SERVER_DIR
#   - GGUF models in LLM_MODELS_ROOT (default: ~/models)
#   - claude (Claude Code CLI)
#   - curl, stat, find
#
# Note for macOS users: the system bash is 3.2 (too old for this script).
# Use zsh (the default since Catalina) or install a newer bash:
#   brew install bash
#
# Models are auto-discovered from LLM_MODELS_ROOT. To add a new model,
# just download the GGUF files into any subdirectory of LLM_MODELS_ROOT.
# They'll appear in llm-list and llm-set automatically.
#
# Usage:
#   claude-planner              → Launch Claude Code with active planner
#   claude-coder                → Launch Claude Code with active coder
#
#   llm-set <role>              → Interactively configure a role
#                                   role: planner | coder
#   llm-list                    → List discovered GGUF models
#   llm-active                  → Show current selections per role
#   llm-unset <role>            → Clear active selection
#   llm-status                  → Show running server info
#   llm-stop                    → Stop the server
#   llm-logs                    → Tail server logs
# =============================================================================

# ── Shell detection ──────────────────────────────────────────────────────────

if [ -n "${ZSH_VERSION:-}" ]; then
  _LLM_SHELL="zsh"
elif [ -n "${BASH_VERSION:-}" ]; then
  _LLM_SHELL="bash"
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "llm-ctl: bash 4+ required (you have ${BASH_VERSION})." >&2
    echo "  On macOS: use zsh (default) or install newer bash via Homebrew." >&2
    return 1 2>/dev/null || exit 1
  fi
else
  echo "llm-ctl: unsupported shell (need bash 4+ or zsh)." >&2
  return 1 2>/dev/null || exit 1
fi

# ── Configuration ────────────────────────────────────────────────────────────
# All of these can be overridden via environment variables before sourcing.

LLM_PORT="${LLM_PORT:-8080}"
LLM_SERVER_DIR="${LLM_SERVER_DIR:-$HOME/llama.cpp}"
LLM_MODELS_ROOT="${LLM_MODELS_ROOT:-$HOME/models}"
LLM_CONFIG="${LLM_CONFIG:-$HOME/.local-llm-config}"
LLM_PIDFILE="${LLM_PIDFILE:-/tmp/llm-server.pid}"
LLM_MODELFILE="${LLM_MODELFILE:-/tmp/llm-server.model}"
LLM_LOCKFILE="${LLM_LOCKFILE:-/tmp/llm-server.lock}"
LLM_LOGFILE="${LLM_LOGFILE:-/tmp/llm-server.log}"

LLM_DEFAULT_CTX="${LLM_DEFAULT_CTX:-65536}"
LLM_DEFAULT_TEMP_PLANNER="${LLM_DEFAULT_TEMP_PLANNER:-0.7}"
LLM_DEFAULT_TEMP_CODER="${LLM_DEFAULT_TEMP_CODER:-0.2}"

# Context-size options shown in the interactive picker
_LLM_CTX_OPTIONS="16384 32768 65536 131072 262144"

# ── Portable helpers ─────────────────────────────────────────────────────────

# Split a space-separated string into an array, portably.
# Sets _LLM_ARR as a result array.
_llm_split() {
  local list="$1"
  if [ "$_LLM_SHELL" = "zsh" ]; then
    _LLM_ARR=(${=list})
  else
    _LLM_ARR=($list)
  fi
}

# Echo the Nth element (1-indexed) of a space-separated string.
_llm_nth() {
  local n="$1"
  local list="$2"
  _llm_split "$list"
  if [ "$_LLM_SHELL" = "zsh" ]; then
    echo "${_LLM_ARR[$n]}"
  else
    echo "${_LLM_ARR[$((n - 1))]}"
  fi
}

# Count words in a space-separated string.
_llm_wc() {
  _llm_split "$1"
  echo "${#_LLM_ARR[@]}"
}

# Cross-platform file size in bytes.
_llm_stat_size() {
  local s
  s="$(stat -f%z "$1" 2>/dev/null)"
  [ -n "$s" ] && { echo "$s"; return; }
  s="$(stat -c%s "$1" 2>/dev/null)"
  [ -n "$s" ] && { echo "$s"; return; }
  # Final fallback
  s="$(wc -c < "$1" 2>/dev/null)"
  s="${s// /}"
  echo "$s"
}

# ── Associative array config store ───────────────────────────────────────────
# Keys: role.field  (e.g. planner.model, coder.ctx)

if [ "$_LLM_SHELL" = "zsh" ]; then
  typeset -gA LLM_CFG
else
  declare -gA LLM_CFG
fi
LLM_CFG=()

_llm_load_config() {
  LLM_CFG=()
  [ -f "$LLM_CONFIG" ] || return 0
  local key value
  while IFS='=' read -r key value; do
    if [ -n "$key" ] && [ -n "$value" ]; then
      LLM_CFG[$key]="$value"
    fi
  done < "$LLM_CONFIG"
}

_llm_save_config() {
  : > "$LLM_CONFIG"
  local key
  if [ "$_LLM_SHELL" = "zsh" ]; then
    for key in "${(@k)LLM_CFG}"; do
      echo "$key=${LLM_CFG[$key]}" >> "$LLM_CONFIG"
    done
  else
    for key in "${!LLM_CFG[@]}"; do
      echo "$key=${LLM_CFG[$key]}" >> "$LLM_CONFIG"
    done
  fi
}

_llm_get() { echo "${LLM_CFG[$1.$2]:-}"; }
_llm_set_field() { LLM_CFG[$1.$2]="$3"; }
_llm_unset_field() { unset "LLM_CFG[$1.$2]"; }

_llm_load_config

# ── Model discovery ──────────────────────────────────────────────────────────

_llm_list_models() {
  [ -d "$LLM_MODELS_ROOT" ] || return 0
  find "$LLM_MODELS_ROOT" -type f -name "*.gguf" 2>/dev/null | \
    awk '
      {
        if ($0 ~ /-[0-9]{5}-of-[0-9]{5}\.gguf$/) {
          if ($0 ~ /-00001-of-[0-9]{5}\.gguf$/) print $0
        } else {
          print $0
        }
      }
    ' | sort
}

_llm_friendly_name() {
  local path="$1"
  local rel="${path#$LLM_MODELS_ROOT/}"
  local dir="${rel%/*}"

  case "$dir" in
    */UD-*|*/Q[0-9]*|*/IQ[0-9]*|*/MXFP*)
      echo "$dir"
      ;;
    *)
      local base="${path##*/}"
      base="${base%.gguf}"
      case "$base" in
        *-00001-of-[0-9][0-9][0-9][0-9][0-9])
          base="${base%-00001-of-*}"
          ;;
      esac
      if [ "$dir" = "$rel" ]; then
        echo "$base"
      else
        echo "$dir/$base"
      fi
      ;;
  esac
}

_llm_file_size() {
  local path="$1"

  case "$path" in
    *-00001-of-[0-9][0-9][0-9][0-9][0-9].gguf)
      # Split model — extract shard count and sum all shards
      local fname="${path##*/}"
      local suffix="${fname%.gguf}"
      local total_shards="${suffix##*-of-}"
      local shards_int=$((10#$total_shards))
      local base="${path%-00001-of-*}"
      local total=0
      local i padded shard s
      for ((i = 1; i <= shards_int; i++)); do
        padded=$(printf "%05d" "$i")
        shard="${base}-${padded}-of-${total_shards}.gguf"
        if [ -f "$shard" ]; then
          s=$(_llm_stat_size "$shard")
          total=$((total + s))
        fi
      done
      echo "$(( total / 1024 / 1024 / 1024 )) GB"
      ;;
    *)
      local size
      size=$(_llm_stat_size "$path")
      if [ -n "$size" ] && [ "$size" -gt 0 ] 2>/dev/null; then
        if [ "$size" -gt 1073741824 ]; then
          echo "$(( size / 1024 / 1024 / 1024 )) GB"
        else
          echo "$(( size / 1024 / 1024 )) MB"
        fi
      fi
      ;;
  esac
}

_llm_model_exists() { [ -f "$1" ]; }

# ── Server helpers ───────────────────────────────────────────────────────────

_llm_server_running() {
  [ -f "$LLM_PIDFILE" ] && kill -0 "$(cat "$LLM_PIDFILE")" 2>/dev/null
}

_llm_current_model() {
  if [ -f "$LLM_MODELFILE" ]; then
    cat "$LLM_MODELFILE"
  else
    echo ""
  fi
}

_llm_active_sessions() {
  local count=0
  if [ -f "$LLM_LOCKFILE" ]; then
    local live_pids="" pid
    while IFS= read -r pid; do
      if kill -0 "$pid" 2>/dev/null; then
        count=$((count + 1))
        live_pids="${live_pids}${pid}
"
      fi
    done < "$LLM_LOCKFILE"
    printf '%s' "$live_pids" > "$LLM_LOCKFILE"
  fi
  echo "$count"
}

_llm_register_session() { echo "$$" >> "$LLM_LOCKFILE"; }

_llm_unregister_session() {
  if [ -f "$LLM_LOCKFILE" ]; then
    grep -v "^$$\$" "$LLM_LOCKFILE" > "${LLM_LOCKFILE}.tmp" 2>/dev/null || true
    mv "${LLM_LOCKFILE}.tmp" "$LLM_LOCKFILE" 2>/dev/null || true
  fi
}

_llm_wait_for_server() {
  local max_wait=300
  local waited=0
  printf "  Waiting for server to be ready"
  while ! curl -s "http://localhost:$LLM_PORT/health" >/dev/null 2>&1; do
    sleep 2
    waited=$((waited + 2))
    printf "."
    if [ "$waited" -ge "$max_wait" ]; then
      echo " timeout!"
      echo "  Check logs: $LLM_LOGFILE"
      return 1
    fi
  done
  echo " ready!"
}

_llm_start_server() {
  local model_path="$1"
  local ctx="$2"
  local temp="$3"

  echo "  Starting llama-server..."
  echo "  Model: $(_llm_friendly_name "$model_path")"
  echo "  Context: $ctx  Temp: $temp"

  if [ ! -x "$LLM_SERVER_DIR/llama-server" ]; then
    echo "  ✗ llama-server not found at $LLM_SERVER_DIR/llama-server"
    echo "  Set LLM_SERVER_DIR or build llama.cpp first."
    return 1
  fi

  nohup "$LLM_SERVER_DIR/llama-server" \
    -m "$model_path" \
    --ctx-size "$ctx" \
    --temp "$temp" --top-p 0.8 --top-k 20 --min-p 0.00 \
    --port "$LLM_PORT" \
    --host 127.0.0.1 \
    > "$LLM_LOGFILE" 2>&1 &

  echo $! > "$LLM_PIDFILE"
  echo "$model_path" > "$LLM_MODELFILE"

  _llm_wait_for_server
}

_llm_stop_server() {
  if _llm_server_running; then
    local pid
    pid=$(cat "$LLM_PIDFILE")
    echo "  Stopping server (PID $pid)..."
    kill "$pid" 2>/dev/null
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 15 ]; do
      sleep 1
      waited=$((waited + 1))
    done
    kill -9 "$pid" 2>/dev/null
    rm -f "$LLM_PIDFILE" "$LLM_MODELFILE"
    echo "  ✓ Server stopped"
  fi
}

# ── Interactive prompts ──────────────────────────────────────────────────────

_llm_prompt_model() {
  local role="$1"
  local current="$2"

  local models_raw
  models_raw=$(_llm_list_models)

  if [ -z "$models_raw" ]; then
    echo "  ✗ No GGUF models found in $LLM_MODELS_ROOT" >&2
    echo "  Download models into that directory first." >&2
    return 1
  fi

  local count
  count=$(printf '%s\n' "$models_raw" | wc -l | tr -d ' ')

  {
    echo ""
    echo "  Select $role model:"
    echo ""
    local i=1 m marker name size
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      marker=" "
      [ "$m" = "$current" ] && marker="*"
      name=$(_llm_friendly_name "$m")
      size=$(_llm_file_size "$m")
      printf "    %2d.%s %-50s %s\n" "$i" "$marker" "$name" "$size"
      i=$((i + 1))
    done <<< "$models_raw"
    echo ""
    printf "  Select [1-%d]: " "$count"
  } >&2

  local choice
  read -r choice

  if [ -z "$choice" ] || [ "$choice" -lt 1 ] 2>/dev/null || [ "$choice" -gt "$count" ] 2>/dev/null; then
    echo "  ✗ Invalid selection" >&2
    return 1
  fi

  local i=1 m
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    if [ "$i" = "$choice" ]; then
      echo "$m"
      return 0
    fi
    i=$((i + 1))
  done <<< "$models_raw"
  return 1
}

_llm_prompt_ctx() {
  local current="$1"
  local default="${current:-$LLM_DEFAULT_CTX}"

  _llm_split "$_LLM_CTX_OPTIONS"
  local options_count="${#_LLM_ARR[@]}"

  {
    echo ""
    echo "  Context size (tokens):"
    echo ""
    local i=1 c marker
    for c in "${_LLM_ARR[@]}"; do
      marker=" "
      [ "$c" = "$default" ] && marker="*"
      printf "    %d.%s %d\n" "$i" "$marker" "$c"
      i=$((i + 1))
    done
    echo "    c.  custom"
    echo ""
    printf "  Select [default: %s]: " "$default"
  } >&2

  local choice
  read -r choice

  if [ -z "$choice" ]; then
    echo "$default"
    return 0
  fi

  if [ "$choice" = "c" ] || [ "$choice" = "C" ]; then
    printf "  Enter custom context size: " >&2
    local custom
    read -r custom
    if [ "$custom" -ge 1024 ] 2>/dev/null; then
      echo "$custom"
    else
      echo "  ✗ Invalid size, using default $default" >&2
      echo "$default"
    fi
    return 0
  fi

  if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$options_count" ] 2>/dev/null; then
    _llm_nth "$choice" "$_LLM_CTX_OPTIONS"
    return 0
  fi

  echo "  ✗ Invalid, using default $default" >&2
  echo "$default"
}

_llm_prompt_temp() {
  local role="$1"
  local current="$2"
  local default

  if [ -n "$current" ]; then
    default="$current"
  elif [ "$role" = "coder" ]; then
    default="$LLM_DEFAULT_TEMP_CODER"
  else
    default="$LLM_DEFAULT_TEMP_PLANNER"
  fi

  printf "\n  Temperature [default: %s]: " "$default" >&2

  local choice
  read -r choice

  if [ -z "$choice" ]; then
    echo "$default"
    return 0
  fi

  # Basic float validation
  case "$choice" in
    [0-9]*.[0-9]*|[0-9]*)
      echo "$choice"
      ;;
    *)
      echo "  ✗ Invalid, using default $default" >&2
      echo "$default"
      ;;
  esac
}

# ── Public commands ──────────────────────────────────────────────────────────

llm-list() {
  echo ""
  echo "  Models in $LLM_MODELS_ROOT:"
  echo ""

  local models_raw
  models_raw=$(_llm_list_models)

  if [ -z "$models_raw" ]; then
    echo "    (none found)"
    echo ""
    return 0
  fi

  local planner_model coder_model
  planner_model=$(_llm_get planner model)
  coder_model=$(_llm_get coder model)

  local m tags name size
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    tags=""
    [ "$m" = "$planner_model" ] && tags="${tags} [planner]"
    [ "$m" = "$coder_model" ] && tags="${tags} [coder]"
    name=$(_llm_friendly_name "$m")
    size=$(_llm_file_size "$m")
    printf "    %-50s %-10s%s\n" "$name" "$size" "$tags"
  done <<< "$models_raw"
  echo ""
}

llm-active() {
  echo ""
  local role model ctx temp status name
  for role in planner coder; do
    model=$(_llm_get "$role" model)
    if [ -n "$model" ]; then
      ctx=$(_llm_get "$role" ctx)
      temp=$(_llm_get "$role" temp)
      status="✓"
      _llm_model_exists "$model" || status="✗ missing"
      name=$(_llm_friendly_name "$model")
      echo "  $role:"
      echo "    model:  $name  ($status)"
      echo "    ctx:    $ctx"
      echo "    temp:   $temp"
    else
      echo "  $role: (not set — run 'llm-set $role')"
    fi
    echo ""
  done
}

llm-set() {
  local role="$1"

  if [ "$role" != "planner" ] && [ "$role" != "coder" ]; then
    echo "  Usage: llm-set <planner|coder>"
    return 1
  fi

  local current_model current_ctx current_temp
  current_model=$(_llm_get "$role" model)
  current_ctx=$(_llm_get "$role" ctx)
  current_temp=$(_llm_get "$role" temp)

  local model
  model=$(_llm_prompt_model "$role" "$current_model") || return 1

  local ctx
  ctx=$(_llm_prompt_ctx "$current_ctx")

  local temp
  temp=$(_llm_prompt_temp "$role" "$current_temp")

  _llm_set_field "$role" model "$model"
  _llm_set_field "$role" ctx "$ctx"
  _llm_set_field "$role" temp "$temp"
  _llm_save_config

  echo ""
  echo "  ✓ $role configured:"
  echo "    model:  $(_llm_friendly_name "$model")"
  echo "    ctx:    $ctx"
  echo "    temp:   $temp"
  echo ""
}

llm-unset() {
  local role="$1"
  if [ "$role" != "planner" ] && [ "$role" != "coder" ]; then
    echo "  Usage: llm-unset <planner|coder>"
    return 1
  fi
  _llm_unset_field "$role" model
  _llm_unset_field "$role" ctx
  _llm_unset_field "$role" temp
  _llm_save_config
  echo "  ✓ Cleared $role"
}

_llm_launch_claude() {
  local role="$1"
  shift

  local model
  model=$(_llm_get "$role" model)

  if [ -z "$model" ]; then
    echo ""
    echo "  ✗ No $role model configured."
    echo "  Run: llm-set $role"
    echo ""
    return 1
  fi

  if ! _llm_model_exists "$model"; then
    echo "  ✗ Model file missing: $model"
    echo "  Run: llm-set $role"
    return 1
  fi

  local ctx temp
  ctx=$(_llm_get "$role" ctx)
  temp=$(_llm_get "$role" temp)

  echo ""
  echo "╭─────────────────────────────────────────╮"
  echo "│  Local LLM · $role"
  echo "│    $(_llm_friendly_name "$model")"
  echo "│    ctx=$ctx  temp=$temp"
  echo "╰─────────────────────────────────────────╯"

  local current
  current=$(_llm_current_model)

  if _llm_server_running && [ "$current" = "$model" ]; then
    echo "  ✓ Already serving"
  elif _llm_server_running && [ "$current" != "$model" ]; then
    local sessions
    sessions=$(_llm_active_sessions)
    if [ "$sessions" -gt 0 ]; then
      echo ""
      echo "  ✗ Cannot swap: current model has $sessions active session(s)."
      echo "  Exit those sessions first, or run 'llm-stop' to force."
      echo ""
      return 1
    fi
    echo "  Swapping model..."
    _llm_stop_server
    _llm_start_server "$model" "$ctx" "$temp" || return 1
  else
    _llm_start_server "$model" "$ctx" "$temp" || return 1
  fi

  echo ""

  _llm_register_session
  trap '_llm_unregister_session' EXIT INT TERM

  ANTHROPIC_BASE_URL="http://localhost:$LLM_PORT" \
  ANTHROPIC_AUTH_TOKEN="local" \
  ANTHROPIC_API_KEY="" \
  claude "$@"

  _llm_unregister_session
  trap - EXIT INT TERM
}

claude-planner() { _llm_launch_claude planner "$@"; }
claude-coder()   { _llm_launch_claude coder "$@"; }

llm-status() {
  echo ""
  if _llm_server_running; then
    local current sessions pid mem
    current=$(_llm_current_model)
    sessions=$(_llm_active_sessions)
    pid=$(cat "$LLM_PIDFILE")
    echo "  Server:   running (PID $pid)"
    echo "  Model:    $(_llm_friendly_name "$current")"
    echo "  Port:     $LLM_PORT"
    echo "  Sessions: $sessions active"
    echo "  Logs:     $LLM_LOGFILE"
    mem=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$mem" ] && echo "  Memory:   $(( mem / 1024 )) MB"
  else
    echo "  Server:   not running"
  fi
  echo ""
}

llm-stop() {
  local sessions
  sessions=$(_llm_active_sessions)
  if [ "$sessions" -gt 0 ]; then
    echo ""
    echo "  ⚠ $sessions active session(s) will lose connection."
    printf "  Continue? [y/N] "
    local confirm
    read -r confirm
    case "$confirm" in
      y|Y|yes|YES) ;;
      *) echo "  Cancelled."; return 0 ;;
    esac
  fi
  _llm_stop_server
  rm -f "$LLM_LOCKFILE"
}

llm-logs() { tail -f "$LLM_LOGFILE"; }