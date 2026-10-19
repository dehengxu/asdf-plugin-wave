# asdf-plugin-wave

An [asdf](https://asdf-community.com/) plugin for [Wave Terminal](https://www.waveterm.dev/)
(`wavetermdev/waveterm`).

Wave ships **prebuilt, versioned, per-architecture archives** on GitHub releases, which is
exactly the shape asdf's version model expects. There is no compilation step: the plugin
resolves the right asset, downloads it, verifies its sha256 and unpacks it.

## Supported platforms

| Host | `uname -m` | asset selected | CLI entry after install |
|---|---|---|---|
| macOS | `arm64` | `Wave-darwin-arm64-<v>.zip` | `Wave.app/Contents/MacOS/Wave` |
| macOS | `x86_64` | `Wave-darwin-x64-<v>.zip` | `Wave.app/Contents/MacOS/Wave` |
| Linux | `aarch64` / `arm64` | `waveterm-linux-arm64-<v>.zip` | `waveterm` |
| Linux | `x86_64` / `amd64` | `waveterm-linux-x64-<v>.zip` | `waveterm` |
| Windows (Git Bash) | `x86_64` | `Wave-win32-x64-<v>.zip` | `Wave.exe` → `bin/wave.cmd` |
| Windows on ARM | `aarch64` | `Wave-win32-x64-<v>.zip` | x64 emulation — there is no native arm64 build |

Verify the matrix yourself, offline, against a recorded release:

```bash
./lib/releases.py selftest
```

### Why asset resolution is dynamic

Wave's asset naming is inconsistent, so nothing is hardcoded:

- **macOS and Windows** use `Wave-darwin-*` / `Wave-win32-*`.
- **Linux** uses `waveterm-linux-*`, and publishes the *same CPU* under two
  different spellings — `x64`/`amd64`/`x86_64`, `arm64`/`aarch64`.
- Only the electron-builder spellings (`x64`, `arm64`) carry a `.zip`. The
  Debian-style spellings ship `deb`/`rpm`/`pacman`/`AppImage` instead.

So a Linux `x86_64` host must ask for asset `x64`, not `x86_64`. `lib/releases.py pick`
queries the release's actual asset list and tries `format → arch` in preference
order, so it adapts if upstream renames or drops a target. (The asset list has been
observed to differ between API responses for the same release, which is why the
plugin never trusts a baked-in table at runtime.)

### Rosetta 2 does not fool it

Architecture detection deliberately asks the **hardware**, not the process. On
Apple Silicon, an x86_64 `asdf` — or anything else running translated — spawns
plugin scripts in an environment where `uname -m` answers `x86_64` even though
the CPU can run `arm64`. Trusting `uname -m` there silently installs the Intel
build.

`host_arch()` resolves this via `sysctl -n hw.optional.arm64` (a hardware feature
flag, unaffected by translation), falling back to actually executing
`arch -arm64 /usr/bin/true`. So a Rosetta-translated asdf on an M-series Mac
still installs the native `arm64` package.

`zip` is always preferred: it is self-contained and needs no root. On Linux,
`AppImage` is the only non-zip fallback, since an AppImage is a single
self-extracting executable that can simply be placed and marked executable.

## Why not just `brew install --cask wave`?

Both are supported and they are not mutually exclusive. The difference:

| | `brew install --cask wave` | this plugin |
|---|---|---|
| versions on disk | one | every version you install, side by side |
| upgrading | automatic (`auto_updates true`) | explicit, `asdf install wave latest` |
| rolling back | not possible | `asdf global wave 0.13.0` |
| platforms | macOS only | macOS, Linux, Windows |
| install location | `/Applications/Wave.app` | `~/.asdf/installs/wave/<version>` |

Use the cask if you want a terminal that just stays current on macOS. Use this
plugin if you pin versions, bisect a regression, keep a known-good build around,
or want the same workflow on Linux and Windows.

## Requirements

- macOS (arm64/x64), Linux (arm64/x64) or Windows with Git Bash
- asdf >= 0.16
- `python3` on PATH (reads the GitHub release API)

## Install

```bash
# from a local checkout
asdf plugin add wave /Users/dehengxu/Projects/personal/asdf-plugin-wave

# or once it is on GitHub
asdf plugin add wave https://github.com/<you>/asdf-plugin-wave

asdf install wave latest
asdf global  wave latest
asdf reshim  wave
```

### Rate limits

`asdf list wave` calls the GitHub releases API, which allows **60 unauthenticated
requests per hour**. Export a token to raise it to 5000:

```bash
export GITHUB_TOKEN=ghp_...   # or GH_TOKEN
```

The download step verifies a sha256 against the digest published in the release
metadata. If it cannot fetch that digest (for example when rate limited) it warns
loudly instead of failing silently.

## Use the GUI on macOS

asdf deliberately does not touch `/Applications` — that is shared state, and
replacing an app bundle there behind your back would be rude. Link it explicitly:

```bash
~/Projects/personal/asdf-plugin-wave/lib/link-macos-app.sh
```

This creates `/Applications/Wave.app` as a symlink to whichever version is currently
selected. It **refuses to overwrite a real app bundle**, so if you also have the
Homebrew cask installed it will tell you how to resolve the conflict rather than
clobbering it. On Linux and Windows the installed binary *is* the app, so nothing
extra is needed.

```bash
lib/link-macos-app.sh --unlink   # remove the symlink (only ever a symlink)
```

After switching versions, re-run the script to repoint `/Applications`.

## How it works

```
bin/list-all        versions from the GitHub releases API, beta-sorted
bin/latest-stable   newest non-prerelease
bin/download        resolve asset for this host, download + verify sha256
bin/install         unpack, place the CLI entry point, write the shim wrapper
bin/help.overview   `asdf help wave`
lib/releases.py     GitHub API client (list / latest / assets / pick / digest / selftest)
lib/utils.bash      os + arch detection, sorting, download, install
lib/link-macos-app.sh  the /Applications helper above
```

Three details worth knowing:

- **The CLI entry point is a wrapper script, not a symlink.** The payload is an
  Electron app, and Electron resolves its Frameworks relative to the real
  executable path. A symlink would make `process.execPath` point at the shim and
  the app would fail to launch. On Windows the equivalent is a CRLF-terminated
  `bin/wave.cmd`.

- **`ditto` is preferred over `unzip` for extraction** because it preserves the
  bundle's symlinks, permissions and extended attributes. The macOS archive
  contains ~14 symlinks inside `Electron Framework.framework`; if `ditto` fails the
  plugin clears its partial tree before falling back to `unzip`, which refuses to
  recreate a symlink that already exists.

- **The installer exec-bits are forced**, because zip archives do not reliably
  preserve permissions on `waveterm` / `chrome-sandbox`.

## Troubleshooting

**Installed the x64 build on an Apple Silicon Mac** — you are running a
Rosetta-translated asdf. Check with:

```bash
file "$(command -v asdf)"   # "Mach-O 64-bit executable x86_64" == translated
```

Update the plugin so it detects the hardware rather than the process, then
reinstall:

```bash
asdf plugin update wave
asdf uninstall wave <version> && asdf install wave <version>
```

The result should name an `arm64` asset. In the long run, reinstall asdf itself
from an `arm64` build so it stops paying the translation cost for every plugin.

**`no downloadable build for darwin/arm64`** — upstream renamed or dropped the
asset. The error lists every published asset for that release; pick one that
matches your CPU or pass `WAVE_FORMATS` to change the format preference.

**`GitHub API rate limited` on `asdf list wave`** — export `GITHUB_TOKEN`.

**Linux: `waveterm: required file not found` at runtime** — the AppImage fallback
needs either FUSE or `--appimage-extract-and-run`. Install on a host whose
`uname -m` maps to a `zip` asset if you hit this.

**The app will not open; "damaged" or a Gatekeeper prompt (macOS)** — the install
may have been interrupted:

```bash
xattr -dr com.apple.quarantine /Applications/Wave.app
asdf uninstall wave <version> && asdf install wave <version>
```

**`wave` command not found** — `asdf reshim wave`. The shim is generated from
`<install-dir>/bin/wave` (or `bin/wave.cmd` on Windows), not from the app bundle.
