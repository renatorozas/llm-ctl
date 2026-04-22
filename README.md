# llm-ctl

Shell script that manages local GGUF models and connects them to Claude Code via llama.cpp.

Assign models to roles (planner for architecture/reasoning, coder for execution) and launch Claude Code sessions against them while optionally keeping a cloud Opus session running in VS Code.

## Requirements

- **zsh 5+** (default on macOS since Catalina) or **bash 4+**
  - macOS system bash is 3.2 — use zsh or `brew install bash`
- **llama-server** from [llama.cpp](https://github.com/ggml-org/llama.cpp)
- **claude** ([Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI)
- **hf** CLI *(optional — for `llm-ctl download`)*

## Dependencies

If you already have these, skip to [Install](#install).

**llama.cpp** — build from source:

```sh
git clone https://github.com/ggml-org/llama.cpp && cd llama.cpp
cmake -B build && cmake --build build --config Release -j
```

Point `LLMCTL_SERVER_DIR` at the directory containing `llama-server` (add to your shell rc):

```sh
export LLMCTL_SERVER_DIR="$HOME/llama.cpp/build/bin"
```

See the [llama.cpp build guide](https://github.com/ggml-org/llama.cpp#build) for GPU acceleration and platform-specific options. On macOS, Homebrew is an alternative:

```sh
brew install llama.cpp
export LLMCTL_SERVER_DIR="$(dirname "$(which llama-server)")"
```

**Claude Code**:

```sh
npm install -g @anthropic-ai/claude-code
```

See the [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code) for setup and authentication.

**hf CLI** *(optional — only needed for `llm-ctl download`)*:

```sh
pip install -U "huggingface_hub[cli]"
```

## Install

Once dependencies are in place, install llm-ctl:

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

## Quick Start

1. Download a model:

   ```sh
   llm-ctl download bartowski/Qwen2.5-Coder-32B-Instruct-GGUF --include '*.Q4_K_M.gguf'
   ```

   Or place GGUF files manually in `~/models` (see `LLMCTL_MODELS_ROOT` in [Configuration](#configuration) to change the path).

2. Configure a role:

   ```sh
   llm-ctl set planner    # interactive: pick model, context size, temperature
   llm-ctl set coder
   ```

3. Launch:

   ```sh
   llm-ctl planner
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
| `LLMCTL_SERVER_DIR` | `~/llama.cpp` | Path to directory containing `llama-server` |
| `LLMCTL_MODELS_ROOT` | `~/models` | Where to find GGUF files |
| `LLMCTL_DEFAULT_CTX` | `65536` | Default context size |
| `LLMCTL_DEFAULT_TEMP_PLANNER` | `0.7` | Default planner temperature |
| `LLMCTL_DEFAULT_TEMP_CODER` | `0.2` | Default coder temperature |

## License

MIT
