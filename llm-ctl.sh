#!/usr/bin/env bash
# =============================================================================
# llm-ctl — Local LLM Manager for Claude Code
# =============================================================================
# Works with both zsh and bash 4+ on macOS, Linux, and WSL.
#
# Install:
#   curl -fsSL https://raw.githubusercontent.com/renatorozas/llm-ctl/main/install.sh | sh
#
# Manual setup:
#   1. Place this file somewhere (e.g. ~/.llm-ctl/llm-ctl.sh)
#   2. Source it from your shell rc file:
#        source ~/.llm-ctl/llm-ctl.sh
#   3. Reload your shell: exec $SHELL
#
# Requirements:
#   - bash 4+ OR zsh 5+
#   - llama-server (from llama.cpp) — see LLMCTL_SERVER_DIR
#   - GGUF models in LLMCTL_MODELS_ROOT (default: ~/models)
#   - claude (Claude Code CLI)
#   - curl, stat, find
#
# Note for macOS users: the system bash is 3.2 (too old for this script).
# Use zsh (the default since Catalina) or install a newer bash:
#   brew install bash
#
# Models are auto-discovered from LLMCTL_MODELS_ROOT. To add a new model,
# just download the GGUF files into any subdirectory of LLMCTL_MODELS_ROOT.
# They'll appear in llm-ctl list and llm-ctl set automatically.
#
# Usage:
#   llm-ctl planner             → Launch Claude Code with active planner
#   llm-ctl coder               → Launch Claude Code with active coder
#
#   llm-ctl set <role>           → Interactively configure a role
#                                    role: planner | coder
#   llm-ctl list                 → List discovered GGUF models
#   llm-ctl active               → Show current selections per role
#   llm-ctl unset <role>         → Clear active selection
#   llm-ctl download <repo>     → Download a model from Hugging Face
#   llm-ctl status               → Show running server info
#   llm-ctl stop                 → Stop the server
#   llm-ctl logs                 → Tail server logs
#   llm-ctl help                 → Show available commands
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

LLMCTL_PORT="${LLMCTL_PORT:-8080}"
LLMCTL_SERVER_DIR="${LLMCTL_SERVER_DIR:-$HOME/llama.cpp}"
LLMCTL_MODELS_ROOT="${LLMCTL_MODELS_ROOT:-$HOME/models}"
LLMCTL_CONFIG="${LLMCTL_CONFIG:-$HOME/.local-llm-config}"
LLMCTL_PIDFILE="${LLMCTL_PIDFILE:-/tmp/llm-server.pid}"
LLMCTL_MODELFILE="${LLMCTL_MODELFILE:-/tmp/llm-server.model}"
LLMCTL_LOCKFILE="${LLMCTL_LOCKFILE:-/tmp/llm-server.lock}"
LLMCTL_LOGFILE="${LLMCTL_LOGFILE:-/tmp/llm-server.log}"

LLMCTL_DEFAULT_CTX="${LLMCTL_DEFAULT_CTX:-65536}"
LLMCTL_DEFAULT_TEMP_PLANNER="${LLMCTL_DEFAULT_TEMP_PLANNER:-0.7}"
LLMCTL_DEFAULT_TEMP_CODER="${LLMCTL_DEFAULT_TEMP_CODER:-0.2}"

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
  typeset -gA _LLMCTL_CFG
else
  declare -gA _LLMCTL_CFG
fi
_LLMCTL_CFG=()

_llm_load_config() {
  _LLMCTL_CFG=()
  [ -f "$LLMCTL_CONFIG" ] || return 0
  local key value
  while IFS='=' read -r key value; do
    if [ -n "$key" ] && [ -n "$value" ]; then
      _LLMCTL_CFG[$key]="$value"
    fi
  done < "$LLMCTL_CONFIG"
}

_llm_save_config() {
  : > "$LLMCTL_CONFIG"
  local key
  if [ "$_LLM_SHELL" = "zsh" ]; then
    for key in "${(@k)_LLMCTL_CFG}"; do
      echo "$key=${_LLMCTL_CFG[$key]}" >> "$LLMCTL_CONFIG"
    done
  else
    for key in "${!_LLMCTL_CFG[@]}"; do
      echo "$key=${_LLMCTL_CFG[$key]}" >> "$LLMCTL_CONFIG"
    done
  fi
}

_llm_get() { echo "${_LLMCTL_CFG[$1.$2]:-}"; }
_llm_set_field() { _LLMCTL_CFG[$1.$2]="$3"; }
_llm_unset_field() { unset "_LLMCTL_CFG[$1.$2]"; }

_llm_load_config

# ── Model discovery ──────────────────────────────────────────────────────────

_llm_list_models() {
  [ -d "$LLMCTL_MODELS_ROOT" ] || return 0
  find "$LLMCTL_MODELS_ROOT" -type f -name "*.gguf" 2>/dev/null | \
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
  local filepath="$1"
  local rel="${filepath#$LLMCTL_MODELS_ROOT/}"
  local dir="${rel%/*}"

  case "$dir" in
    */UD-*|*/Q[0-9]*|*/IQ[0-9]*|*/MXFP*)
      echo "$dir"
      ;;
    *)
      local base="${filepath##*/}"
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
  local filepath="$1"

  case "$filepath" in
    *-00001-of-[0-9][0-9][0-9][0-9][0-9].gguf)
      # Split model — extract shard count and sum all shards
      local fname="${filepath##*/}"
      local suffix="${fname%.gguf}"
      local total_shards="${suffix##*-of-}"
      local shards_int=$((10#$total_shards))
      local base="${filepath%-00001-of-*}"
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
      size=$(_llm_stat_size "$filepath")
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
  [ -f "$LLMCTL_PIDFILE" ] && kill -0 "$(cat "$LLMCTL_PIDFILE")" 2>/dev/null
}

_llm_current_model() {
  if [ -f "$LLMCTL_MODELFILE" ]; then
    cat "$LLMCTL_MODELFILE"
  else
    echo ""
  fi
}

_llm_active_sessions() {
  local count=0
  if [ -f "$LLMCTL_LOCKFILE" ]; then
    local live_pids="" pid
    while IFS= read -r pid; do
      if kill -0 "$pid" 2>/dev/null; then
        count=$((count + 1))
        live_pids="${live_pids}${pid}
"
      fi
    done < "$LLMCTL_LOCKFILE"
    printf '%s' "$live_pids" > "$LLMCTL_LOCKFILE"
  fi
  echo "$count"
}

_llm_register_session() { echo "$$" >> "$LLMCTL_LOCKFILE"; }

_llm_unregister_session() {
  if [ -f "$LLMCTL_LOCKFILE" ]; then
    grep -v "^$$\$" "$LLMCTL_LOCKFILE" > "${LLMCTL_LOCKFILE}.tmp" 2>/dev/null || true
    mv "${LLMCTL_LOCKFILE}.tmp" "$LLMCTL_LOCKFILE" 2>/dev/null || true
  fi
}

_llm_wait_for_server() {
  local max_wait=300
  local waited=0
  printf "  Waiting for server to be ready"
  while ! curl -s "http://localhost:$LLMCTL_PORT/health" >/dev/null 2>&1; do
    sleep 2
    waited=$((waited + 2))
    printf "."
    if [ "$waited" -ge "$max_wait" ]; then
      echo " timeout!"
      echo "  Check logs: $LLMCTL_LOGFILE"
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

  if [ ! -x "$LLMCTL_SERVER_DIR/llama-server" ]; then
    echo "  ✗ llama-server not found at $LLMCTL_SERVER_DIR/llama-server"
    echo "  Set LLMCTL_SERVER_DIR or build llama.cpp first."
    return 1
  fi

  nohup "$LLMCTL_SERVER_DIR/llama-server" \
    -m "$model_path" \
    --ctx-size "$ctx" \
    --temp "$temp" --top-p 0.8 --top-k 20 --min-p 0.00 \
    --port "$LLMCTL_PORT" \
    --host 127.0.0.1 \
    > "$LLMCTL_LOGFILE" 2>&1 &

  echo $! > "$LLMCTL_PIDFILE"
  echo "$model_path" > "$LLMCTL_MODELFILE"

  _llm_wait_for_server
}

_llm_stop_server() {
  if _llm_server_running; then
    local pid
    pid=$(cat "$LLMCTL_PIDFILE")
    echo "  Stopping server (PID $pid)..."
    kill "$pid" 2>/dev/null
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 15 ]; do
      sleep 1
      waited=$((waited + 1))
    done
    kill -9 "$pid" 2>/dev/null
    rm -f "$LLMCTL_PIDFILE" "$LLMCTL_MODELFILE"
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
    echo "  ✗ No GGUF models found in $LLMCTL_MODELS_ROOT" >&2
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
  local default="${current:-$LLMCTL_DEFAULT_CTX}"

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
    default="$LLMCTL_DEFAULT_TEMP_CODER"
  else
    default="$LLMCTL_DEFAULT_TEMP_PLANNER"
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

_llm_cmd_list() {
  echo ""
  echo "  Models in $LLMCTL_MODELS_ROOT:"
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

_llm_cmd_active() {
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
      echo "  $role: (not set — run 'llm-ctl set $role')"
    fi
    echo ""
  done
}

_llm_cmd_set() {
  local role="$1"

  if [ "$role" != "planner" ] && [ "$role" != "coder" ]; then
    echo "  Usage: llm-ctl set <planner|coder>"
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

_llm_cmd_unset() {
  local role="$1"
  if [ "$role" != "planner" ] && [ "$role" != "coder" ]; then
    echo "  Usage: llm-ctl unset <planner|coder>"
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
    echo "  Run: llm-ctl set $role"
    echo ""
    return 1
  fi

  if ! _llm_model_exists "$model"; then
    echo "  ✗ Model file missing: $model"
    echo "  Run: llm-ctl set $role"
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
      echo "  Exit those sessions first, or run 'llm-ctl stop' to force."
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

  ANTHROPIC_BASE_URL="http://localhost:$LLMCTL_PORT" \
  ANTHROPIC_AUTH_TOKEN="local" \
  ANTHROPIC_API_KEY="" \
  claude "$@"

  _llm_unregister_session
  trap - EXIT INT TERM
}

_llm_cmd_planner() { _llm_launch_claude planner "$@"; }
_llm_cmd_coder()   { _llm_launch_claude coder "$@"; }

_llm_cmd_status() {
  echo ""
  if _llm_server_running; then
    local current sessions pid mem
    current=$(_llm_current_model)
    sessions=$(_llm_active_sessions)
    pid=$(cat "$LLMCTL_PIDFILE")
    echo "  Server:   running (PID $pid)"
    echo "  Model:    $(_llm_friendly_name "$current")"
    echo "  Port:     $LLMCTL_PORT"
    echo "  Sessions: $sessions active"
    echo "  Logs:     $LLMCTL_LOGFILE"
    mem=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$mem" ] && echo "  Memory:   $(( mem / 1024 )) MB"
  else
    echo "  Server:   not running"
  fi
  echo ""
}

_llm_cmd_stop() {
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
  rm -f "$LLMCTL_LOCKFILE"
}

_llm_cmd_logs() { tail -f "$LLMCTL_LOGFILE"; }

_llm_cmd_download() {
  if ! command -v hf >/dev/null 2>&1; then
    echo ""
    echo "  The 'hf' CLI (Hugging Face Hub) is required for downloads."
    echo ""
    if command -v brew >/dev/null 2>&1; then
      echo "  Install it with:"
      echo "    brew install huggingface-cli"
    elif command -v pipx >/dev/null 2>&1; then
      echo "  Install it with:"
      echo "    pipx install huggingface_hub"
    elif command -v pip3 >/dev/null 2>&1; then
      echo "  Install it with:"
      echo "    pip3 install -U 'huggingface_hub[cli]'"
    elif command -v pip >/dev/null 2>&1; then
      echo "  Install it with:"
      echo "    pip install -U 'huggingface_hub[cli]'"
    else
      echo "  Python is required. Install Python first, then run:"
      echo "    pip install -U 'huggingface_hub[cli]'"
    fi
    echo ""
    return 1
  fi

  local repo="$1"
  case "${repo:-}" in
    ""|--*|-*)
      echo ""
      echo "  Usage: llm-ctl download <owner/model> [hf-options]"
      echo ""
      echo "  Examples:"
      echo "    llm-ctl download bartowski/Qwen2.5-Coder-32B-Instruct-GGUF"
      echo "    llm-ctl download bartowski/Qwen2.5-Coder-32B-Instruct-GGUF --include '*.Q4_K_M.gguf'"
      echo ""
      return 1
      ;;
  esac
  shift

  local repo_name="${repo##*/}"
  local dest="$LLMCTL_MODELS_ROOT/$repo_name"

  echo ""
  echo "  Downloading from: $repo"
  echo "  Destination:      $dest"
  echo ""

  hf download "$repo" --local-dir "$dest" "$@"
  local rc=$?

  if [ "$rc" -eq 0 ]; then
    echo ""
    echo "  ✓ Download complete: $dest"
    echo "  Run 'llm-ctl list' to see available models."
    echo ""
  else
    echo ""
    echo "  ✗ Download failed (exit code $rc)" >&2
    echo ""
    return "$rc"
  fi
}

_llm_cmd_help() {
  echo ""
  echo "  llm-ctl — Local LLM Manager"
  echo ""
  echo "  Usage: llm-ctl <command> [args]"
  echo ""
  echo "  Model management:"
  echo "    list                  List discovered GGUF models"
  echo "    active                Show current role configurations"
  echo "    set <role>            Configure a role (planner|coder)"
  echo "    unset <role>          Clear a role's configuration"
  echo "    download <repo>       Download a model from Hugging Face"
  echo ""
  echo "  Server:"
  echo "    status                Show running server info"
  echo "    stop                  Stop the llama-server"
  echo "    logs                  Tail server logs"
  echo ""
  echo "  Launch:"
  echo "    planner [args]        Launch Claude Code with planner model"
  echo "    coder [args]          Launch Claude Code with coder model"
  echo ""
  echo "  help                    Show this help"
  echo ""
}

llm-ctl() {
  local cmd="${1:-help}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    list)     _llm_cmd_list "$@" ;;
    active)   _llm_cmd_active "$@" ;;
    set)      _llm_cmd_set "$@" ;;
    unset)    _llm_cmd_unset "$@" ;;
    status)   _llm_cmd_status "$@" ;;
    stop)     _llm_cmd_stop "$@" ;;
    logs)     _llm_cmd_logs "$@" ;;
    planner)  _llm_cmd_planner "$@" ;;
    coder)    _llm_cmd_coder "$@" ;;
    download) _llm_cmd_download "$@" ;;
    help|-h|--help) _llm_cmd_help ;;
    *)
      echo "  llm-ctl: unknown command '$cmd'" >&2
      echo "  Run 'llm-ctl help' for usage." >&2
      return 1
      ;;
  esac
}

# ── Tab completion ───────────────────────────────────────────────────────────

if [ "$_LLM_SHELL" = "zsh" ]; then
  compctl -k "(list set unset active status stop logs download planner coder help)" llm-ctl
else
  complete -W "list set unset active status stop logs download planner coder help" llm-ctl
fi
