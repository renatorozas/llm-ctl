#!/bin/sh
set -e

REPO_URL="https://raw.githubusercontent.com/renatorozas/llm-ctl/main"
INSTALL_DIR="$HOME/.llm-ctl"
SCRIPT_PATH="$INSTALL_DIR/llm-ctl.sh"
MODELS_DIR="${LLMCTL_MODELS_ROOT:-$HOME/models}"

main() {
  echo ""
  echo "  Installing llm-ctl..."
  echo ""

  if ! command -v curl >/dev/null 2>&1; then
    echo "  Error: curl is required but not found." >&2
    exit 1
  fi

  mkdir -p "$INSTALL_DIR"
  mkdir -p "$MODELS_DIR"

  curl -fsSL "$REPO_URL/llm-ctl.sh" -o "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"

  SOURCE_LINE="source \"$SCRIPT_PATH\""
  RC_FILE=""

  case "$(basename "${SHELL:-}")" in
    zsh)  RC_FILE="$HOME/.zshrc" ;;
    bash) RC_FILE="$HOME/.bashrc" ;;
  esac

  if [ -z "$RC_FILE" ]; then
    if [ -f "$HOME/.zshrc" ]; then
      RC_FILE="$HOME/.zshrc"
    elif [ -f "$HOME/.bashrc" ]; then
      RC_FILE="$HOME/.bashrc"
    fi
  fi

  if [ -n "$RC_FILE" ]; then
    touch "$RC_FILE"
    if ! grep -qF "$SOURCE_LINE" "$RC_FILE"; then
      echo "" >> "$RC_FILE"
      echo "$SOURCE_LINE" >> "$RC_FILE"
      echo "  Added to $RC_FILE:"
      echo "    $SOURCE_LINE"
    else
      echo "  Already in $RC_FILE (skipped)"
    fi
  else
    echo "  Could not detect shell rc file."
    echo "  Add this line to your shell profile manually:"
    echo "    $SOURCE_LINE"
  fi

  echo ""
  echo "  Installed to: $SCRIPT_PATH"
  echo "  Models dir:   $MODELS_DIR"
  echo ""
  echo "  Next steps:"
  echo "    1. Restart your shell:  exec \$SHELL"
  echo "    2. Download a model:    llm-ctl download <huggingface-repo>"
  echo "    3. Configure a role:    llm-ctl set planner"
  echo "    4. Launch:              llm-ctl planner"
  echo ""
}

main
