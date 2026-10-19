#!/usr/bin/env bash

# Shared helpers for the asdf `wave` plugin.
#
# Wave Terminal ships *prebuilt, versioned, per-architecture* archives on GitHub
# releases, which is exactly the shape asdf's version model expects. There is no
# compilation step.
#
# Supported hosts: macOS (arm64/x64), Linux (arm64/x64, incl. Debian-style
# uname spellings), Windows x64 under Git Bash.
#
# Asset naming is resolved at runtime via `lib/releases.py pick` rather than a
# baked-in table -- Wave publishes the same CPU under two different spellings
# on Linux and only one of them carries a .zip.

set -euo pipefail

TOOL_NAME="wave"
GH_REPO="wavetermdev/waveterm"
GH_RELEASE_URL="https://github.com/${GH_REPO}/releases/download"

_utils_self="${BASH_SOURCE[0]:-$0}"
_utils_dir="$(cd "$(dirname "$_utils_self")" && pwd)"
RELEASES_PY="${_utils_dir}/releases.py"
PYTHON="${ASDF_WAVE_PYTHON:-python3}"

APP_NAME="Wave.app"

fail() {
  echo -e "asdf-${TOOL_NAME}: $*" >&2
  exit 1
}

# --- platform detection -----------------------------------------------------

# Token used in Wave's asset filenames (Darwin -> darwin, win32 for Windows).
host_os() {
  case "$(uname -s)" in
    Darwin) echo "darwin" ;;
    Linux) echo "linux" ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT) echo "win32" ;;
    *) fail "unsupported OS '$(uname -s)'" ;;
  esac
}

# Asset arch spellings to try, best first.
#
# On Linux `uname -m` reports x86_64/aarch64 but the .zip is published under
# the electron-builder spelling x64/arm64, so the host spelling must not be
# the only candidate. Windows ships x64 only, so ARM falls back to x64 and
# runs under emulation.
arch_candidates() {
  local m
  m="$(uname -m)"
  case "$m" in
    arm64 | aarch64)
      if [ "$(host_os)" = "win32" ]; then echo "arm64 x64"; else echo "arm64 aarch64"; fi
      ;;
    x86_64 | amd64)
      if [ "$(host_os)" = "win32" ]; then echo "x64"; else echo "x64 amd64 x86_64"; fi
      ;;
    *) echo "$m" ;;
  esac
}

# Formats to try, best first. zip is self-contained and needs no root, so it
# always wins. AppImage is the only non-zip format we can install without a
# package manager (it is a single self-extracting executable).
preferred_formats() {
  if [ -n "${WAVE_FORMATS:-}" ]; then
    echo "$WAVE_FORMATS"
  elif [ "$(host_os)" = "linux" ]; then
    echo "zip AppImage"
  else
    echo "zip"
  fi
}

pick_asset() {
  local version="$1"
  "${PYTHON}" "${RELEASES_PY}" pick \
    "$version" "$(host_os)" "$(arch_candidates)" "$(preferred_formats)"
}

# --- version listing --------------------------------------------------------

# Same normalisation used by the official colima asdf plugin so that
# pre-releases (0.14.5-beta.2) sort below their stable counterpart.
sort_versions() {
  sed 'h; s/[+-]/./g; s/.p\([[:digit:]]\)/.z\1/; s/$/.z/; G; s/\n/ /' |
    LC_ALL=C sort -t. -k 1,1 -k 2,2n -k 3,3n -k 4,4n -k 5,5n |
    awk '{print $2}'
}

list_all_versions() {
  "${PYTHON}" "${RELEASES_PY}" list | sort_versions
}

latest_stable_version() {
  "${PYTHON}" "${RELEASES_PY}" latest
}

# --- download ---------------------------------------------------------------

# 0 when the file matches the digest published by GitHub, 2 when no digest
# could be fetched, 1 on mismatch.
verify_sha256() {
  local file="$1" version="$2" asset="$3" want got
  [ -s "$file" ] || return 1

  want="$("${PYTHON}" "${RELEASES_PY}" digest "$version" "$asset" 2>/dev/null)" || return 2

  got="$(shasum -a 256 "$file" 2>/dev/null | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    echo "* sha256 MISMATCH for ${asset}" >&2
    echo "*   expected ${want}" >&2
    echo "*   actual   ${got}" >&2
    return 1
  fi
  return 0
}

download_release() {
  local version="$1" asset="$2" filename="$3"
  local url="${GH_RELEASE_URL}/v${version}/${asset}"

  mkdir -p "$(dirname "$filename")"

  if [ -s "$filename" ]; then
    if verify_sha256 "$filename" "$version" "$asset"; then
      echo "* Reusing verified download: ${asset}"
      return 0
    fi
    echo "* Existing file failed verification, re-downloading..."
  fi

  echo "* Downloading wave ${version} [${asset}]..."
  curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$filename" "$url" ||
    fail "could not download ${url}"

  if verify_sha256 "$filename" "$version" "$asset"; then
    echo "* sha256 verified against GitHub release digest"
  else
    local rc=$?
    if [ "$rc" -eq 2 ]; then
      echo "* WARNING: no published sha256 digest available; skipping verification" >&2
    else
      fail "sha256 verification failed for ${asset}"
    fi
  fi
}

# --- install ----------------------------------------------------------------

# Entry point of the installed CLI, relative to the install dir.
_resolve_entry() {
  local install_path="$1" os_token="$2"
  case "$os_token" in
    darwin) echo "${APP_NAME}/Contents/MacOS/Wave" ;;
    linux) echo "waveterm" ;;
    win32) echo "Wave.exe" ;;
    *) fail "unsupported OS token '$os_token'" ;;
  esac
}

_write_wrapper() {
  local bin_dir="$1" os_token="$2"

  # Written with printf rather than a heredoc: heredocs need a scratch temp
  # file, which is unavailable in restricted environments.
  if [ "$os_token" = "win32" ]; then
    printf '%s\r\n' \
      '@echo off' \
      'rem Generated by the asdf wave plugin.' \
      '"%~dp0..\Wave.exe" %*' \
      > "${bin_dir}/${TOOL_NAME}.cmd"
    chmod +x "${bin_dir}/${TOOL_NAME}.cmd" 2>/dev/null || true
    return
  fi

  # Deliberately a wrapper script and NOT a symlink: the payload is an
  # Electron app, and Electron resolves resources relative to the real
  # executable path. exec'ing through a symlink makes process.execPath point
  # at the shim and the app fails to find its Frameworks.
  if [ "$os_token" = "darwin" ]; then
    local target='${here}/../Wave.app/Contents/MacOS/Wave'
  else
    local target='${here}/../waveterm'
  fi
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Generated by the asdf wave plugin.' \
    'here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
    "exec \"${target}\" \"\$@\"" \
    > "${bin_dir}/${TOOL_NAME}"
  chmod +x "${bin_dir}/${TOOL_NAME}"
}

install_version() {
  local version="$1" install_path="$2"
  local asset archive os_token entry bin_dir

  os_token="$(host_os)"
  asset="$(pick_asset "$version")" ||
    fail "no downloadable build for $(host_os)/$(uname -m) at v${version}"
  archive="${ASDF_DOWNLOAD_PATH:-${install_path}/.download}/${asset}"

  [ -f "$archive" ] ||
    fail "archive not found: ${archive} (the download step did not run?)"

  entry="$(_resolve_entry "$install_path" "$os_token")"
  bin_dir="${install_path}/bin"
  mkdir -p "$install_path" "$bin_dir"

  case "$asset" in
    *.AppImage)
      # A single self-extracting executable, not an archive: just place it.
      echo "* Installing AppImage ${asset}..."
      cp "$archive" "${install_path}/waveterm"
      chmod +x "${install_path}/waveterm"
      ;;
    *.zip)
      echo "* Unpacking ${asset} into ${install_path}..."
      # ditto preserves the bundle correctly (symlinks, permissions, extended
      # attributes); plain unzip is the fallback.
      #
      # The macOS archive carries ~14 symlinks inside Electron
      # Framework.framework. Extraction must not be left half-finished, so if
      # ditto bails we clear its partial tree before falling back -- unzip
      # refuses to recreate a symlink that already exists.
      if ! ditto_log="$(ditto -x -k "$archive" "$install_path" 2>&1)"; then
        echo "* ditto failed, falling back to unzip:" >&2
        printf '%s\n' "$ditto_log" | sed 's/^/    ditto: /' >&2
        rm -rf "${install_path:?}/${APP_NAME}" 2>/dev/null || true
        unzip -q "$archive" -d "$install_path" ||
          fail "could not unpack ${asset}"
      fi
      ;;
    *)
      fail "unsupported asset format: ${asset} (this plugin installs zip and AppImage)"
      ;;
  esac

  [ -e "${install_path}/${entry}" ] ||
    fail "expected ${install_path}/${entry} after install"

  # Linux ships the electron sandbox helper without the exec bit.
  chmod +x "${install_path}/waveterm" 2>/dev/null || true
  chmod +x "${install_path}/chrome-sandbox" 2>/dev/null || true

  if [ "$os_token" = "darwin" ]; then
    xattr -dr com.apple.quarantine "${install_path}/${APP_NAME}" 2>/dev/null || true
  fi

  _write_wrapper "$bin_dir" "$os_token"

  # Marker so tooling can read the real version without shelling out.
  echo "$version" > "${install_path}/.wave-version"

  local wrapper="${bin_dir}/${TOOL_NAME}"
  [ "$os_token" = "win32" ] && wrapper="${wrapper}.cmd"

  echo
  echo "wave ${version} installed (${os_token}/$(uname -m), asset ${asset})."
  echo "  app bundle : ${install_path}/${entry}"
  echo "  CLI entry  : ${wrapper}  (shim it with: asdf reshim wave)"
  if [ "$os_token" = "darwin" ]; then
    echo
    echo "To use the GUI, symlink the active version into /Applications:"
    echo "  ${_utils_dir}/link-macos-app.sh"
  fi
}
