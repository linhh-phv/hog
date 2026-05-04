#!/usr/bin/env bash
#
# lps installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/linhh-phv/lps/main/install.sh | bash
#
# Override defaults:
#   INSTALL_DIR=~/bin BRANCH=main bash install.sh

set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/linhh-phv/lps}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
BIN_NAME="lps"

C_RED=$'\033[31m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_BOLD=$'\033[1m'
C_RESET=$'\033[0m'

log()   { echo "${C_BOLD}==>${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}warn:${C_RESET} $*" >&2; }
error() { echo "${C_RED}error:${C_RESET} $*" >&2; exit 1; }

# Check OS
case "$(uname -s)" in
  Darwin|Linux) ;;
  *) error "Unsupported OS: $(uname -s). lps only supports macOS and Linux." ;;
esac

# Check required tools
for tool in curl lsof ps awk; do
  command -v "$tool" >/dev/null 2>&1 || error "missing required tool: $tool"
done

# Need write access to INSTALL_DIR
SUDO=""
if [[ ! -w "$INSTALL_DIR" ]]; then
  if [[ -d "$INSTALL_DIR" ]]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO="sudo"
      warn "$INSTALL_DIR is not writable; will use sudo."
    else
      error "$INSTALL_DIR is not writable and sudo is unavailable. Try INSTALL_DIR=~/bin"
    fi
  else
    log "creating $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR" || error "could not create $INSTALL_DIR"
  fi
fi

URL="$REPO_RAW/$BRANCH/$BIN_NAME"
TARGET="$INSTALL_DIR/$BIN_NAME"

log "downloading $URL"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP" || error "download failed"

# Sanity check: must look like our script
if ! head -1 "$TMP" | grep -q '^#!.*bash'; then
  error "downloaded file does not look like a bash script — aborting"
fi

log "installing to $TARGET"
$SUDO install -m 0755 "$TMP" "$TARGET" 2>/dev/null \
  || $SUDO cp "$TMP" "$TARGET" && $SUDO chmod 0755 "$TARGET"

# PATH check
if ! echo ":$PATH:" | grep -q ":$INSTALL_DIR:"; then
  warn "$INSTALL_DIR is not on your PATH. Add this to your shell rc:"
  echo "    export PATH=\"$INSTALL_DIR:\$PATH\""
fi

echo
log "${C_GREEN}done.${C_RESET} run: ${C_BOLD}lps help${C_RESET}"
