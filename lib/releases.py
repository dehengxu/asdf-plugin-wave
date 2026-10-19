#!/usr/bin/env python3
"""GitHub release metadata helper for the asdf `wave` plugin.

Subcommands:
  list                     print every published version, one per line
  latest                   print the latest non-prerelease version
  assets <version>         print the asset names published for one version
  pick <ver> <os> <archs> <formats>
                           print the best asset name for os/arch/format
  digest <version> <asset> print the published sha256 digest for one asset
  selftest                 offline coverage matrix over a recorded release

Wave's asset naming is inconsistent across platforms, which is exactly why
`pick` resolves at runtime instead of guessing from a baked-in table:

  macOS    Wave-darwin-arm64-<v>.zip        Wave-darwin-x64-<v>.zip
  Windows  Wave-win32-x64-<v>.zip           (no arm64 build at all)
  Linux    waveterm-linux-<arch>-<v>.<fmt>

and on Linux the *same* CPU is published under two different spellings, only
one of which carries a .zip:

  uname -m x86_64  ->  asset "x64"     (zip)     "amd64"/"x86_64" (deb/AppImage/rpm)
  uname -m aarch64 ->  asset "arm64"   (zip)     "aarch64"       (pacman/rpm)

Rate limits: the GitHub API allows 60 unauthenticated requests/hour. If
GITHUB_TOKEN (or GH_TOKEN) is exported the limit is raised to 5000/hour.
"""
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.github.com/repos/wavetermdev/waveterm"
PAGES = 10  # safety bound for pagination (100 releases/page)

# Recorded from `releases/latest` (v0.14.5) so `selftest` can run offline.
# Verified asset-by-asset with HTTP HEAD; the API's asset list has been seen
# to disagree with itself, so never trust a table like this at runtime.
V0_14_5_ASSETS = [
    "Wave-darwin-arm64-0.14.5.dmg",
    "Wave-darwin-arm64-0.14.5.zip",
    "Wave-darwin-x64-0.14.5.dmg",
    "Wave-darwin-x64-0.14.5.zip",
    "Wave-win32-x64-0.14.5.exe",
    "Wave-win32-x64-0.14.5.msi",
    "Wave-win32-x64-0.14.5.zip",
    "waveterm-linux-aarch64-0.14.5.pacman",
    "waveterm-linux-amd64-0.14.5.deb",
    "waveterm-linux-arm64-0.14.5.AppImage",
    "waveterm-linux-arm64-0.14.5.deb",
    "waveterm-linux-arm64-0.14.5.zip",
    "waveterm-linux-x64-0.14.5.pacman",
    "waveterm-linux-x64-0.14.5.zip",
    "waveterm-linux-x86_64-0.14.5.AppImage",
    "waveterm-linux-x86_64-0.14.5.rpm",
    "waveterm_0.14.5_amd64.snap",
    "waveterm_0.14.5_arm64.snap",
]


def headers():
    h = {"Accept": "application/vnd.github+json", "User-Agent": "asdf-plugin-wave"}
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        h["Authorization"] = "Bearer " + token
    return h


def get(url):
    req = urllib.request.Request(url, headers=headers())
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def strip_v(tag):
    return tag[1:] if tag[:1] in ("v", "V") else tag


def die(msg):
    sys.stderr.write("asdf_wave: %s\n" % msg)
    sys.exit(1)


def asset_stem(os_token):
    """macOS/Windows use 'Wave-<os>', Linux uses 'waveterm-linux'."""
    return "waveterm-linux" if os_token == "linux" else "Wave-" + os_token


def select_asset(assets, os_token, archs, formats, version):
    """First format wins, then first arch. Returns the asset name or None.

    Formats are ordered by preference, not by arch, because a self-contained
    zip is strongly preferred over a system package that needs root.
    """
    aset = set(assets)
    stem = asset_stem(os_token)
    for fmt in formats:
        for arch in archs:
            name = "%s-%s-%s.%s" % (stem, arch, version, fmt)
            if name in aset:
                return name
    return None


def fetch_release(version):
    return get("%s/releases/tags/v%s" % (API, version))


def cmd_list():
    out = []
    for page in range(1, PAGES + 1):
        try:
            data = get("%s/releases?per_page=100&page=%d" % (API, page))
        except urllib.error.HTTPError as e:
            if e.code == 403 and page == 1:
                die("GitHub API rate limited. Export GITHUB_TOKEN=... and retry.")
            break
        except urllib.error.URLError as e:
            if page == 1:
                die("network error talking to GitHub: %s" % e.reason)
            break
        if not isinstance(data, list) or not data:
            break
        out.extend(data)
    for rel in out:
        if rel.get("draft"):
            continue
        v = strip_v(rel.get("tag_name") or "")
        if v:
            print(v)


def cmd_latest():
    try:
        rel = get(API + "/releases/latest")
    except urllib.error.HTTPError as e:
        die("could not resolve latest release (HTTP %s)" % e.code)
    v = strip_v(rel.get("tag_name") or "")
    if not v:
        die("latest release has no tag_name")
    print(v)


def cmd_assets(version):
    for a in fetch_release(version).get("assets", []):
        print(a["name"])


def cmd_pick(version, os_token, archs, formats):
    names = [a["name"] for a in fetch_release(version).get("assets", [])]
    picked = select_asset(names, os_token, archs.split(), formats.split(), version)
    if not picked:
        sys.stderr.write(
            "asdf_wave: no asset for %s/%s in v%s (tried formats=%s archs=%s)\n"
            % (os_token, archs, version, formats, archs)
        )
        sys.stderr.write("asdf_wave: published assets are:\n")
        for n in sorted(names):
            sys.stderr.write("asdf_wave:   %s\n" % n)
        return 3
    print(picked)
    return 0


def cmd_digest(version, asset):
    """0 + print sha256 on success; 2 asset has no digest; 3 not found; 4 API error."""
    try:
        rel = fetch_release(version)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            sys.stderr.write("asdf_wave: release v%s not found\n" % version)
            return 3
        sys.stderr.write("asdf_wave: API error %s\n" % e.code)
        return 4
    except urllib.error.URLError:
        return 4

    for item in rel.get("assets", []):
        if item.get("name") != asset:
            continue
        digest = (item.get("digest") or "").strip()
        if digest.startswith("sha256:"):
            print(digest.split(":", 1)[1])
            return 0
        sys.stderr.write("asdf_wave: no sha256 published for %s\n" % asset)
        return 2

    sys.stderr.write("asdf_wave: asset %s not in v%s\n" % (asset, version))
    return 3


def cmd_selftest():
    """Offline check that every supported host resolves to a real asset."""
    version = "0.14.5"
    cases = [
        ("darwin", ["arm64"], ["zip", "dmg"], "Wave-darwin-arm64-0.14.5.zip"),
        ("darwin", ["x64"], ["zip", "dmg"], "Wave-darwin-x64-0.14.5.zip"),
        ("linux", ["arm64", "aarch64"], ["zip", "AppImage"],
         "waveterm-linux-arm64-0.14.5.zip"),
        ("linux", ["x64", "amd64", "x86_64"], ["zip", "AppImage"],
         "waveterm-linux-x64-0.14.5.zip"),
        ("win32", ["x64"], ["zip"], "Wave-win32-x64-0.14.5.zip"),
        # Windows on ARM has no native build; falls back to the x64 one.
        ("win32", ["arm64", "x64"], ["zip"], "Wave-win32-x64-0.14.5.zip"),
    ]
    failures = 0
    for os_token, archs, formats, expected in cases:
        got = select_asset(V0_14_5_ASSETS, os_token, archs, formats, version)
        ok = got == expected
        failures += 0 if ok else 1
        print("%-5s %-6s %-28s -> %s" % ("ok" if ok else "FAIL", os_token,
                                         ",".join(archs), got or "<none>"))
    print("\n%d/%d passed" % (len(cases) - failures, len(cases)))
    return 1 if failures else 0


def main(argv):
    if not argv:
        die("usage: releases.py {list|latest|assets|pick|digest|selftest}")
    cmd = argv[0]
    if cmd == "list":
        cmd_list()
    elif cmd == "latest":
        cmd_latest()
    elif cmd == "assets":
        if len(argv) != 2:
            die("usage: releases.py assets <version>")
        cmd_assets(argv[1])
    elif cmd == "pick":
        if len(argv) != 5:
            die("usage: releases.py pick <version> <os> <archs> <formats>")
        return cmd_pick(argv[1], argv[2], argv[3], argv[4])
    elif cmd == "digest":
        if len(argv) != 3:
            die("usage: releases.py digest <version> <asset>")
        return cmd_digest(argv[1], argv[2])
    elif cmd == "selftest":
        return cmd_selftest()
    else:
        die("unknown subcommand: %s" % cmd)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
