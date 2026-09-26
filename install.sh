#!/bin/sh
# install.sh — install the dMatrix extensions plugin into every AI client on this machine.
#
#   curl -fsSL https://www.dmatrix.com/install.sh | sh
#   curl -fsSL https://www.dmatrix.com/install.sh | sh -s -- --dry-run
#
# THE CONTRACT. This header is the single definition of the one-step install, and
# install.ps1 mirrors it exactly — same clients, same per-client commands, same result
# lines, same exit codes. Change one, change both.
#
# Clients. Each client installs the plugin with its own plugin manager and keeps its own
# versioned copy; this script never copies a plugin payload itself.
#   claude  Claude Code        marketplace add/update, then plugin install/update at user
#                              scope.
#   codex   Codex CLI          marketplace add/upgrade, then plugin add. Also covers the
#                              ChatGPT desktop app, which bundles the same CLI and reads
#                              the same ~/.codex/config.toml; the app needs a restart.
#   agy     Antigravity CLI    no marketplace exists, so the repo archive at --ref is
#                              fetched into the cache dir and the bundle installed from
#                              there. Re-fetched on every run.
#
# Surfaces that cannot be scripted — the Claude app (including Cowork), claude.ai, and
# ChatGPT on the web — carry the plugin against your account with no local file
# representing it. They get a pointer to their manual steps and never a failure.
#
# Options:
#   --only claude|codex|agy   one client instead of every client detected
#   --ref <git-ref>           branch or tag to install from (default: main)
#   --dry-run                 print what would happen without changing anything
#   --uninstall               remove what this script installed
#   -h, --help                this text
#
# Environment: DMATRIX_EXTENSIONS_REPO (owner/repo) and DMATRIX_EXTENSIONS_REF override
# where the plugin comes from.
#
# Result lines. Exactly one per client, in client order:
#   "  ok    <client> — <what happened>"     the plugin is installed or updated there
#   "  --    <client> — <why>"               the client is not on this machine
#   "  warn  <client> — <what failed>"       the client is here but the step failed
# Lines starting "  --  " that name no client are notes, not results. A final summary
# counts them: "Done. <n> installed or updated, <n> skipped, <n> failed."
#
# Exit codes:
#   0  at least one client was installed or updated (or would be, under --dry-run)
#   1  nothing could be installed — no supported client is on this machine, every
#      detected client failed, or this is a Windows shell (use install.ps1)
#   2  the command line was wrong
#
# No sudo. Writes only under the clients' own homes and the cache dir, and is safe to
# re-run: a re-run updates every copy already installed.

set -eu

REPO="${DMATRIX_EXTENSIONS_REPO:-lockstride/dmatrix-extensions}"
REF="${DMATRIX_EXTENSIONS_REF:-main}"
MARKETPLACE="dmatrix-extensions"
PLUGIN="dmatrix"
PLUGIN_ID="${PLUGIN}@${MARKETPLACE}"
# Where the Antigravity plugin bundle sits inside the repo archive.
BUNDLE_PATH="google/antigravity/dmatrix"
CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/dmatrix-extensions"

CLAUDE_MANUAL="https://github.com/lockstride/dmatrix-extensions/blob/main/claude/README.md"
OPENAI_MANUAL="https://github.com/lockstride/dmatrix-extensions/blob/main/openai/README.md"

only=""
dry_run=0
uninstall=0

n_ok=0
n_skip=0
n_fail=0

usage() {
  cat <<'USAGE'
Usage: install.sh [--only claude|codex|agy] [--ref <git-ref>] [--dry-run] [--uninstall]

Installs the dMatrix plugin into every AI client found on this machine, each through its
own plugin manager: Claude Code, Codex CLI (which also covers the ChatGPT desktop app),
and Antigravity CLI. Prints one result line per client. Safe to re-run — a re-run updates
every copy already installed.

  --only claude|codex|agy   one client instead of every client detected
  --ref <git-ref>           branch or tag to install from (default: main)
  --dry-run                 print what would happen without changing anything
  --uninstall               remove what this script installed
  -h, --help                this text

The Claude app (including Cowork), claude.ai, and ChatGPT on the web install against your
account and cannot be scripted; this prints their manual steps instead.

On Windows, use install.ps1:  irm https://www.dmatrix.com/install.ps1 | iex
USAGE
}

say() { printf '%s\n' "$*"; }
note() { printf '  --    %s\n' "$*"; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}
have() { command -v "$1" >/dev/null 2>&1; }

ok() {
  printf '  ok    %s\n' "$*"
  n_ok=$((n_ok + 1))
}

skip() {
  printf '  --    %s\n' "$*"
  n_skip=$((n_skip + 1))
}

warn() {
  printf '  warn  %s\n' "$*" >&2
  n_fail=$((n_fail + 1))
}

# Runs a command, or prints it under --dry-run. Always succeeds in a dry run so the
# result lines and the exit code are the same as a real run's.
run() {
  if [ "$dry_run" = 1 ]; then
    printf '  would run: %s\n' "$*"
  else
    "$@"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
  --only)
    shift
    only="${1:-}"
    ;;
  --only=*) only="${1#--only=}" ;;
  --ref)
    shift
    REF="${1:-}"
    ;;
  --ref=*) REF="${1#--ref=}" ;;
  --dry-run) dry_run=1 ;;
  --uninstall) uninstall=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

case "$only" in
"" | claude | codex | agy) ;;
*) die "--only takes claude, codex, or agy, not '$only'" ;;
esac
[ -n "$REF" ] || die "--ref needs a value"

# --- Claude Code ----------------------------------------------------------------------

claude_marketplace_present() {
  claude plugin marketplace list --json 2>/dev/null | grep -q "\"${MARKETPLACE}\""
}

claude_plugin_present() {
  claude plugin list --json 2>/dev/null | grep -q "\"${PLUGIN_ID}\""
}

# What `claude plugin marketplace add` is given: the bare repo for the default branch,
# and the git URL with a ref fragment when --ref pins one.
claude_source() {
  if [ "$REF" = "main" ]; then
    printf '%s\n' "$REPO"
  else
    printf 'https://github.com/%s.git#%s\n' "$REPO" "$REF"
  fi
}

install_claude() {
  if claude_marketplace_present; then
    if ! run claude plugin marketplace update "$MARKETPLACE"; then
      warn "Claude Code — could not refresh the ${MARKETPLACE} marketplace"
      return 1
    fi
  else
    claude_src="$(claude_source)"
    if ! run claude plugin marketplace add "$claude_src"; then
      warn "Claude Code — could not add the ${MARKETPLACE} marketplace"
      return 1
    fi
  fi
  if claude_plugin_present; then
    if ! run claude plugin update "$PLUGIN_ID" --scope user -y; then
      warn "Claude Code — could not update ${PLUGIN_ID}"
      return 1
    fi
    ok "Claude Code — updated ${PLUGIN_ID} at user scope"
  else
    if ! run claude plugin install "$PLUGIN_ID" --scope user -y; then
      warn "Claude Code — could not install ${PLUGIN_ID}"
      return 1
    fi
    ok "Claude Code — installed ${PLUGIN_ID} at user scope"
  fi
  note "Claude Code — new sessions load it; in an open session run /reload-plugins"
}

uninstall_claude() {
  if claude_plugin_present; then
    if ! run claude plugin uninstall "$PLUGIN_ID" --scope user -y; then
      warn "Claude Code — could not uninstall ${PLUGIN_ID}"
      return 1
    fi
    ok "Claude Code — uninstalled ${PLUGIN_ID}"
  else
    skip "Claude Code — ${PLUGIN_ID} is not installed"
  fi
  if claude_marketplace_present; then
    run claude plugin marketplace remove "$MARKETPLACE" ||
      warn "Claude Code — could not remove the ${MARKETPLACE} marketplace"
  fi
}

# --- Codex CLI (and the ChatGPT desktop app) -------------------------------------------

codex_has_plugins() { codex plugin --help >/dev/null 2>&1; }

codex_marketplace_present() {
  codex plugin marketplace list 2>/dev/null | grep -qE "^${MARKETPLACE}[[:space:]]"
}

# The table's STATUS column reads "installed, enabled" for an installed plugin and
# "not installed" otherwise, so anchoring on "installed" after the id distinguishes them.
codex_plugin_present() {
  codex plugin list 2>/dev/null | grep -qE "^${PLUGIN_ID}[[:space:]]+installed"
}

install_codex() {
  if ! codex_has_plugins; then
    warn "Codex CLI — this version has no plugin commands; update Codex and re-run"
    return 1
  fi
  if codex_marketplace_present; then
    if ! run codex plugin marketplace upgrade "$MARKETPLACE"; then
      warn "Codex CLI — could not refresh the ${MARKETPLACE} marketplace"
      return 1
    fi
  elif [ "$REF" = "main" ]; then
    if ! run codex plugin marketplace add "$REPO"; then
      warn "Codex CLI — could not add the ${MARKETPLACE} marketplace"
      return 1
    fi
  else
    if ! run codex plugin marketplace add "$REPO" --ref "$REF"; then
      warn "Codex CLI — could not add the ${MARKETPLACE} marketplace"
      return 1
    fi
  fi
  codex_had=0
  if codex_plugin_present; then codex_had=1; fi
  if ! run codex plugin add "$PLUGIN_ID"; then
    warn "Codex CLI — could not install ${PLUGIN_ID}"
    return 1
  fi
  if [ "$codex_had" = 1 ]; then
    ok "Codex CLI — updated ${PLUGIN_ID}"
  else
    ok "Codex CLI — installed ${PLUGIN_ID}"
  fi
  note "Codex CLI — new sessions load it; restart the ChatGPT desktop app to pick it up"
}

uninstall_codex() {
  if ! codex_has_plugins; then
    warn "Codex CLI — this version has no plugin commands; nothing to remove"
    return 1
  fi
  if codex_plugin_present; then
    if ! run codex plugin remove "$PLUGIN_ID"; then
      warn "Codex CLI — could not uninstall ${PLUGIN_ID}"
      return 1
    fi
    ok "Codex CLI — uninstalled ${PLUGIN_ID}"
  else
    skip "Codex CLI — ${PLUGIN_ID} is not installed"
  fi
  if codex_marketplace_present; then
    run codex plugin marketplace remove "$MARKETPLACE" ||
      warn "Codex CLI — could not remove the ${MARKETPLACE} marketplace"
  fi
}

# --- Antigravity CLI -------------------------------------------------------------------

# Antigravity installs a plugin from a directory, not a marketplace, so the bundle has to
# be on disk first. The cache dir is replaced on every run, which is what makes a re-run
# an update.
fetch_bundle() {
  archive_url="https://github.com/${REPO}/archive/${REF}.tar.gz"
  tarball="${CACHE_DIR}.tar.gz"
  if [ "$dry_run" = 1 ]; then
    printf '  would run: %s\n' "curl -fsSL -o ${tarball} ${archive_url}"
    printf '  would run: %s\n' "tar -xzf ${tarball} --strip-components=1 -C ${CACHE_DIR}"
    return 0
  fi
  rm -rf "$CACHE_DIR"
  mkdir -p "$CACHE_DIR"
  if ! curl -fsSL -o "$tarball" "$archive_url"; then
    rm -f "$tarball"
    return 1
  fi
  if ! tar -xzf "$tarball" --strip-components=1 -C "$CACHE_DIR"; then
    rm -f "$tarball"
    return 1
  fi
  rm -f "$tarball"
}

install_agy() {
  if ! have curl; then
    warn "Antigravity CLI — curl is needed to fetch the plugin bundle"
    return 1
  fi
  if ! fetch_bundle; then
    warn "Antigravity CLI — could not fetch ${REPO} at ${REF}"
    return 1
  fi
  if ! run agy plugin install "${CACHE_DIR}/${BUNDLE_PATH}"; then
    warn "Antigravity CLI — could not install ${PLUGIN}"
    return 1
  fi
  ok "Antigravity CLI — installed ${PLUGIN} from the fetched bundle"
  note "Antigravity CLI — restart agy, then check /skills and /mcp"
}

uninstall_agy() {
  # Antigravity's removal command is the one step in this script that no dMatrix release
  # has exercised on a real install, so a failure here is reported as a manual step
  # rather than treated as the client failing.
  if run agy plugin uninstall "$PLUGIN"; then
    ok "Antigravity CLI — uninstalled ${PLUGIN}"
  else
    note "Antigravity CLI — 'agy plugin uninstall ${PLUGIN}' failed; remove it by hand"
    note "Antigravity CLI — check 'agy plugin list' for the name it is registered under"
    n_skip=$((n_skip + 1))
  fi
  if [ -d "$CACHE_DIR" ] || [ "$dry_run" = 1 ]; then
    run rm -rf "$CACHE_DIR"
  fi
}

# --- Manual surfaces -------------------------------------------------------------------

manual_steps() {
  say ""
  say "Three surfaces install against your account, not this machine, so they take a few"
  say "clicks each. Their steps:"
  say "  The Claude app and claude.ai:  ${CLAUDE_MANUAL}"
  say "  ChatGPT on the web:            ${OPENAI_MANUAL}"
}

# --- Main ------------------------------------------------------------------------------

summary() {
  say ""
  if [ "$dry_run" = 1 ]; then
    say "Dry run: nothing was changed."
  fi
  if [ "$uninstall" = 1 ]; then
    printf 'Done. %s removed, %s skipped, %s failed.\n' "$n_ok" "$n_skip" "$n_fail"
  else
    printf 'Done. %s installed or updated, %s skipped, %s failed.\n' \
      "$n_ok" "$n_skip" "$n_fail"
  fi
}

main() {
  case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    say "This is a Windows shell. Install with PowerShell instead:"
    say "  irm https://www.dmatrix.com/install.ps1 | iex"
    exit 1
    ;;
  esac

  want_claude=0
  want_codex=0
  want_agy=0
  if [ "$only" = "" ] || [ "$only" = "claude" ]; then
    if have claude; then want_claude=1; fi
  fi
  if [ "$only" = "" ] || [ "$only" = "codex" ]; then
    if have codex; then want_codex=1; fi
  fi
  if [ "$only" = "" ] || [ "$only" = "agy" ]; then
    if have agy; then want_agy=1; fi
  fi

  if [ -n "$only" ] &&
    [ "$want_claude" = 0 ] && [ "$want_codex" = 0 ] && [ "$want_agy" = 0 ]; then
    say "'${only}' is not on PATH, so there is nothing to do."
    exit 1
  fi

  if [ "$want_claude" = 0 ] && [ "$want_codex" = 0 ] && [ "$want_agy" = 0 ]; then
    say "No supported client is on PATH (looked for claude, codex, agy)."
    say "Install one of them and re-run, or follow the manual steps:"
    say "  The Claude app and claude.ai:  ${CLAUDE_MANUAL}"
    say "  ChatGPT on the web:            ${OPENAI_MANUAL}"
    exit 1
  fi

  if [ "$uninstall" = 1 ]; then
    say "Removing dMatrix"
    if [ "$want_claude" = 1 ]; then uninstall_claude || true; fi
    if [ "$want_codex" = 1 ]; then uninstall_codex || true; fi
    if [ "$want_agy" = 1 ]; then uninstall_agy || true; fi
    summary
    return 0
  fi

  say "Installing dMatrix from ${REPO} at ${REF}"
  if [ "$want_claude" = 1 ]; then install_claude || true; fi
  if [ "$want_codex" = 1 ]; then install_codex || true; fi
  if [ "$want_agy" = 1 ]; then install_agy || true; fi
  # Only mention the account-side surfaces when every detected client was handled; a run
  # narrowed with --only is answering a narrower question.
  if [ -z "$only" ]; then manual_steps; fi
  summary
  if [ "$n_ok" = 0 ]; then return 1; fi
}

main
