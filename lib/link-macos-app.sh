#!/usr/bin/env bash

# Point /Applications/Wave.app at whichever wave version asdf currently has
# selected, so the GUI runs the same build as the `wave` CLI shim.
#
# This is deliberately a separate, explicit step rather than something
# `asdf install` does behind your back: /Applications is shared state, and
# silently replacing an app bundle there would be rude.
#
#   link-macos-app.sh            # link /Applications/Wave.app -> active version
#   link-macos-app.sh --unlink   # remove the symlink (only if it is one)
#
# Set WAVE_APP_LINK_PATH to point somewhere other than /Applications
# (used by the test suite).

set -euo pipefail

APP_NAME="Wave.app"
DEST="${WAVE_APP_LINK_PATH:-/Applications/${APP_NAME}}"
ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}"

log() { printf '%s\n' "$*"; }
die() { printf 'link-macos-app: %s\n' "$*" >&2; exit 1; }

# Only meaningful on macOS.
if [ "$(uname -s)" != "Darwin" ]; then
  die "this helper is macOS-only (you are on $(uname -s)); on Linux and Windows the GUI is the installed binary itself"
fi

active_install_dir() {
  # Ask asdf first — it already resolved .tool-versions for us.
  if command -v asdf >/dev/null 2>&1; then
    local current
    current="$(asdf current wave 2>/dev/null || true)"
    if [ -n "$current" ]; then
      local path
      path="$(printf '%s\n' "$current" | awk '{print $NF}')"
      if [ -d "$path/${APP_NAME}" ]; then
        printf '%s\n' "$path"
        return 0
      fi
    fi
  fi

  # Fall back to the newest installed version.
  local base="${ASDF_DATA_DIR}/installs/wave"
  [ -d "$base" ] || return 1
  local newest
  newest="$(ls -1 "$base" 2>/dev/null |
    sort -V |
    tail -1)"
  [ -n "$newest" ] || return 1
  printf '%s\n' "${base}/${newest}"
}

unlink_mode=false
if [ "${1:-}" = "--unlink" ]; then
  unlink_mode=true
elif [ -n "${1:-}" ]; then
  die "unknown argument: $1"
fi

if [ "$unlink_mode" = true ]; then
  if [ -L "$DEST" ]; then
    rm "$DEST"
    log "removed symlink ${DEST}"
  elif [ -e "$DEST" ]; then
    die "${DEST} is a real app, not a symlink — refusing to delete it"
  else
    log "nothing to do: ${DEST} does not exist"
  fi
  exit 0
fi

src="$(active_install_dir)" ||
  die "no wave installation found under ${ASDF_DATA_DIR}/installs/wave"

if [ ! -d "${src}/${APP_NAME}" ]; then
  die "${src}/${APP_NAME} is missing — reinstall with: asdf install wave latest"
fi

if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  if [ ! -L "$DEST" ]; then
    log "${DEST} exists and is a real application bundle, not a symlink."
    log "It was probably installed via 'brew install --cask wave'. Pick one:"
    log "  1) keep the cask install:  brew uninstall --cask wave"
    log "  2) keep it and move it:    sudo mv '${DEST}' '${DEST}.bak'"
    log "Then re-run this script."
    exit 1
  fi
  rm "$DEST"
fi

ln -s "${src}/${APP_NAME}" "$DEST" ||
  die "could not create ${DEST} (you may need sudo)"

version="$(cat "${src}/.wave-version" 2>/dev/null || echo unknown)"
log "${DEST} -> ${src}/${APP_NAME}  (wave ${version})"
log "Switch versions with: asdf install wave <version> && asdf global wave <version>, then re-run this script."
