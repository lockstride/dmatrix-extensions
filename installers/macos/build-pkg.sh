#!/bin/sh
# build-pkg.sh — build dmatrix.pkg, the macOS installer, unsigned.
#
#   pnpm extensions:build:pkg
#   sh installers/macos/build-pkg.sh --script install.sh --out dist/installers/dmatrix.pkg
#
# The package's payload is install.sh itself — the same file the one-step command runs, not
# a copy of its logic — installed to /Library/Application Support/dMatrix/ and executed by
# the postinstall as the console user. Everything the installer does, the script does.
#
# Options:
#   --script <path>    the install.sh to package (default: ./install.sh)
#   --version <v>      the package version (default: read from the sources below)
#   --out <path>       where to write the package (default: dist/installers/dmatrix.pkg)
#   -h, --help         this text
#
# The version defaults to PLUGIN_VERSION, read from packages/canonical-prompt/src/version.ts
# in the master repo or .claude-plugin/plugin.json in the rendered extensions repo, so the
# package version and the plugin version are the same number by construction.
#
# Signing is not done here. The release workflow signs and notarizes when the signing
# secrets are present; until then what this produces is what ships (DMA-204).

set -eu

IDENTIFIER="com.dmatrix.extensions"
INSTALL_LOCATION="/Library/Application Support/dMatrix"

script_path=""
version=""
out_path=""

usage() {
  cat <<'USAGE'
Usage: build-pkg.sh [--script <install.sh>] [--version <v>] [--out <path>]

Builds the unsigned macOS installer around install.sh. Requires pkgbuild and productbuild,
so it runs on macOS only.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
  --script)
    shift
    script_path="${1:-}"
    ;;
  --script=*) script_path="${1#--script=}" ;;
  --version)
    shift
    version="${1:-}"
    ;;
  --version=*) version="${1#--version=}" ;;
  --out)
    shift
    out_path="${1:-}"
    ;;
  --out=*) out_path="${1#--out=}" ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    printf 'error: unknown option: %s (try --help)\n' "$1" >&2
    exit 2
    ;;
  esac
  shift
done

[ -n "$script_path" ] || script_path="install.sh"
[ -n "$out_path" ] || out_path="dist/installers/dmatrix.pkg"

# The first "version": in a JSON or TS source is PLUGIN_VERSION in both layouts.
read_version() {
  [ -f "$1" ] || return 1
  found="$(sed -n 's/.*[Vv][Ee][Rr][Ss][Ii][Oo][Nn]["[:space:]]*[:=][[:space:]]*"\([0-9][^"]*\)".*/\1/p' "$1" | head -n 1)"
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

if [ -z "$version" ]; then
  version="$(read_version "packages/canonical-prompt/src/version.ts" ||
    read_version ".claude-plugin/plugin.json" || true)"
fi
[ -n "$version" ] || {
  printf 'error: could not determine the version; pass --version\n' >&2
  exit 2
}

[ -f "$script_path" ] || {
  printf 'error: no install script at %s\n' "$script_path" >&2
  exit 2
}
command -v pkgbuild >/dev/null 2>&1 || {
  printf 'error: pkgbuild is missing; this builds on macOS only\n' >&2
  exit 2
}

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

mkdir -p "$work/root" "$work/scripts" "$work/resources" "$(dirname "$out_path")"
cp "$script_path" "$work/root/install.sh"
chmod 0755 "$work/root/install.sh"
cp "$here/scripts/postinstall" "$work/scripts/postinstall"
chmod 0755 "$work/scripts/postinstall"
cp "$here/resources/welcome.html" "$here/resources/conclusion.html" "$work/resources/"
sed "s/__VERSION__/${version}/g" "$here/distribution.xml" >"$work/distribution.xml"

pkgbuild \
  --root "$work/root" \
  --scripts "$work/scripts" \
  --identifier "$IDENTIFIER" \
  --version "$version" \
  --install-location "$INSTALL_LOCATION" \
  "$work/component.pkg" >/dev/null

productbuild \
  --distribution "$work/distribution.xml" \
  --resources "$work/resources" \
  --package-path "$work" \
  "$out_path" >/dev/null

printf 'built %s (%s, unsigned)\n' "$out_path" "$version"
