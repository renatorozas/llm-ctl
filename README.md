# llm-ctl

Shell script that manages local GGUF models and connects them to Claude Code via llama.cpp.

Assign models to roles (planner for architecture/reasoning, coder for execution) and launch Claude Code sessions against them while optionally keeping a cloud Opus session running in VS Code.

## Requirements

- **zsh 5+** (default on macOS since Catalina) or **bash 4+**
  - macOS system bash is 3.2 — use zsh or `brew install bash`
- **llama-server** from [llama.cpp](https://github.com/ggerganov/llama.cpp)
- **claude** ([Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI)
- **hf** CLI (for `llm-ctl download`) — `pip install -U 'huggingface_hub[cli]'`
- GGUF model files in `~/models` (or set `LLMCTL_MODELS_ROOT`)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/renatorozas/llm-ctl/main/install.sh | sh
```

Then restart your shell:

```sh
exec $SHELL
```

<details>
<summary>Manual install</summary>

1. Clone or copy `llm-ctl.sh`:

   ```sh
   git clone https://github.com/renatorozas/llm-ctl.git
   mkdir -p ~/.llm-ctl
   cp llm-ctl/llm-ctl.sh ~/.llm-ctl/llm-ctl.sh
   ```

2. Source it from your shell rc file:

   ```sh
   # ~/.zshrc or ~/.bashrc
   source ~/.llm-ctl/llm-ctl.sh
   ```

3. Reload your shell: `exec $SHELL`

</details>

## Setup

1. Download a model:

   ```sh
   # Download a specific quantization
   llm-ctl download bartowski/Qwen2.5-Coder-32B-Instruct-GGUF --include '*.Q4_K_M.gguf'

   # Download all files from a repo
   llm-ctl download bartowski/Llama-3.2-1B-Instruct-GGUF

   # Download only model files (skip configs, readmes, etc.)
   llm-ctl download bartowski/Qwen2.5-Coder-32B-Instruct-GGUF --include '*.gguf'
   ```

   All arguments after the repo name are forwarded to `hf download` — run
   `hf download --help` for the full list. Do not pass `--local-dir`; it is
   set automatically to `$LLMCTL_MODELS_ROOT/<repo-name>/`.

   Or manually place GGUF files in `~/models` (subdirectories work too).

   To use a different models path, set `LLMCTL_MODELS_ROOT` before sourcing:

   ```sh
   export LLMCTL_MODELS_ROOT="/path/to/your/models"
   ```

2. Configure a role:

   ```sh
   llm-ctl set planner    # interactive: pick model, context size, temperature
   llm-ctl set coder
   ```

## Usage

```sh
# Launch Claude Code with a local model
llm-ctl planner              # Use the planner model
llm-ctl coder                # Use the coder model

# Manage models
llm-ctl list                  # List discovered GGUF models
llm-ctl active                # Show current role configurations
llm-ctl set <role>            # Configure a role (planner or coder)
llm-ctl unset <role>          # Clear a role's configuration
llm-ctl download <repo>      # Download a model from Hugging Face

# Server management
llm-ctl status                # Show running server info
llm-ctl stop                  # Stop the llama-server
llm-ctl logs                  # Tail server logs
```

## How It Works

- Models are auto-discovered from `LLMCTL_MODELS_ROOT` (default: `~/models`)
- Only one llama-server runs at a time; models swap automatically when needed
- Active Claude Code sessions are tracked to prevent unsafe model swaps
- Configuration persists across shell restarts to `~/.local-llm-config`

## Configuration

All settings have sensible defaults. Override via environment variables before sourcing:

| Variable | Default | Description |
|----------|---------|-------------|
| `LLMCTL_PORT` | `8080` | llama-server port |
| `LLMCTL_SERVER_DIR` | `~/llama.cpp` | Path to llama.cpp build |
| `LLMCTL_MODELS_ROOT` | `~/models` | Where to find GGUF files |
| `LLMCTL_DEFAULT_CTX` | `65536` | Default context size |
| `LLMCTL_DEFAULT_TEMP_PLANNER` | `0.7` | Default planner temperature |
| `LLMCTL_DEFAULT_TEMP_CODER` | `0.2` | Default coder temperature |

## License

MIT
