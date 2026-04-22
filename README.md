# llm-ctl

Shell script that manages local GGUF models and connects them to Claude Code via llama.cpp.

Assign models to roles (planner for architecture/reasoning, coder for execution) and launch Claude Code sessions against them while optionally keeping a cloud Opus session running in VS Code.

## Requirements

- **zsh 5+** (default on macOS since Catalina) or **bash 4+**
  - macOS system bash is 3.2 — use zsh or `brew install bash`
- **llama-server** from [llama.cpp](https://github.com/ggerganov/llama.cpp)
- **claude** ([Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI)
- GGUF model files in `~/models` (or set `LLM_MODELS_ROOT`)

## Setup

1. Clone or copy `llm-ctl.sh` somewhere:

   ```sh
   git clone <repo-url>
   # or just copy the script
   cp llm-ctl.sh ~/llm-ctl.sh
   ```

2. Source it from your shell rc file:

   ```sh
   # ~/.zshrc or ~/.bashrc
   source ~/llm-ctl.sh
   ```

3. Create a models directory and add your GGUF files:

   ```sh
   mkdir -p ~/models
   # Download or copy your .gguf files into ~/models (subdirectories work too)
   ```

   To use a different path, set `LLM_MODELS_ROOT` before sourcing:

   ```sh
   export LLM_MODELS_ROOT="/path/to/your/models"
   ```

4. Reload your shell:

   ```sh
   exec $SHELL
   ```

5. Configure a role:

   ```sh
   llm-set planner    # interactive: pick model, context size, temperature
   llm-set coder
   ```

## Usage

```sh
# Launch Claude Code with a local model
claude-planner              # Use the planner model
claude-coder                # Use the coder model

# Manage models
llm-list                    # List discovered GGUF models
llm-active                  # Show current role configurations
llm-set <role>              # Configure a role (planner or coder)
llm-unset <role>            # Clear a role's configuration

# Server management
llm-status                  # Show running server info
llm-stop                    # Stop the llama-server
llm-logs                    # Tail server logs
```

## How It Works

- Models are auto-discovered from `LLM_MODELS_ROOT` (default: `~/models`)
- Only one llama-server runs at a time; models swap automatically when needed
- Active Claude Code sessions are tracked to prevent unsafe model swaps
- Configuration persists across shell restarts to `~/.local-llm-config`

## Configuration

All settings have sensible defaults. Override via environment variables before sourcing:

| Variable | Default | Description |
|----------|---------|-------------|
| `LLM_PORT` | `8080` | llama-server port |
| `LLM_SERVER_DIR` | `~/llama.cpp` | Path to llama.cpp build |
| `LLM_MODELS_ROOT` | `~/models` | Where to find GGUF files |
| `LLM_DEFAULT_CTX` | `65536` | Default context size |
| `LLM_DEFAULT_TEMP_PLANNER` | `0.7` | Default planner temperature |
| `LLM_DEFAULT_TEMP_CODER` | `0.2` | Default coder temperature |

## License

MIT
