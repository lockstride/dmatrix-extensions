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
#   --no-updater              install without the scheduled updater
#   --update                  the scheduled updater's own mode (see below)
#   --scheduler <kind>        launchd, systemd, or cron instead of what this OS suggests
#   -h, --help                this text
#
# Environment: DMATRIX_EXTENSIONS_REPO (owner/repo) and DMATRIX_EXTENSIONS_REF override
# where the plugin comes from.
#
# The updater. No client refreshes a third-party marketplace on its own, so an install
# also leaves behind a copy of this script and a daily job that runs that local copy with
# --update: a launchd LaunchAgent on macOS, a systemd user timer (or a crontab line) on
# Linux. --update is quiet, touches only clients that already have the plugin, and runs
# nothing but those clients' own update commands - it never fetches code and executes it.
# Its output goes to a log; a failure also raises a desktop notification naming that log.
# --no-updater skips all of it, and --uninstall removes the job, the copy, and the log.
#
# Result lines. Exactly one per client, in client order:
#   "  ok    <client> — <what happened>"     the plugin is installed or updated there
#   "  --    <client> — <why>"               the client is not on this machine
#   "  warn  <client> — <what failed>"       the client is here but the step failed
# A final summary counts them: "Done. <n> installed or updated, <n> skipped, <n> failed."
# Lines naming no client, and the updater's own lines, are notes rather than results: the
# summary counts clients, so registering the updater never changes those numbers.
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

# How a copy of this script recognizes itself. The installed copy the updater runs is
# taken from the running file when there is one; under `curl ... | sh` there is no file to
# copy, so this marker is what tells the two cases apart.
# dmatrix-extensions-install-script

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

UPDATER_LABEL="com.dmatrix.extensions-updater"
UPDATER_UNIT="dmatrix-extensions-updater"
# One day, in seconds. The claim the updater has to keep is "on the new version within
# 24h", so the interval is the claim.
UPDATER_INTERVAL=86400
# The crontab line's trailing marker — what identifies our entry among the user's own.
CRON_MARKER="# ${UPDATER_LABEL}"

PLATFORM="$(uname -s)"

if [ "$PLATFORM" = Darwin ]; then
  SUPPORT_DIR="${HOME}/Library/Application Support/dMatrix"
  SCHEDULER_DEFAULT=launchd
else
  SUPPORT_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/dmatrix"
  SCHEDULER_DEFAULT=systemd
fi
LOCAL_SCRIPT="${SUPPORT_DIR}/install.sh"
LOG_FILE="${SUPPORT_DIR}/update.log"
PLIST_PATH="${HOME}/Library/LaunchAgents/${UPDATER_LABEL}.plist"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"

only=""
dry_run=0
uninstall=0
no_updater=0
update_mode=0
scheduler=""

n_ok=0
n_skip=0
n_fail=0

usage() {
  cat <<'USAGE'
Usage: install.sh [--only claude|codex|agy] [--ref <git-ref>] [--dry-run] [--uninstall]
                  [--no-updater] [--scheduler launchd|systemd|cron]

Installs the dMatrix plugin into every AI client found on this machine, each through its
own plugin manager: Claude Code, Codex CLI (which also covers the ChatGPT desktop app),
and Antigravity CLI. Prints one result line per client. Safe to re-run — a re-run updates
every copy already installed.

  --only claude|codex|agy   one client instead of every client detected
  --ref <git-ref>           branch or tag to install from (default: main)
  --dry-run                 print what would happen without changing anything
  --uninstall               remove what this script installed, updater included
  --no-updater              install without the daily updater
  --update                  what the updater runs: quiet, updates installed clients only
  --scheduler <kind>        launchd, systemd, or cron instead of this OS's default
  -h, --help                this text

An install also registers a daily job that re-runs the clients' own update commands, so a
new release reaches every installed client without you doing anything. It runs a copy of
this script kept beside its log, and never fetches code to execute.

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

# A warning about something that is not one of the clients — the updater. Shaped like a
# client warning so it reads the same, but outside the counts, which are per client.
alert() {
  printf '  warn  %s\n' "$*" >&2
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
  --no-updater) no_updater=1 ;;
  --update) update_mode=1 ;;
  --scheduler)
    shift
    scheduler="${1:-}"
    ;;
  --scheduler=*) scheduler="${1#--scheduler=}" ;;
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
case "$scheduler" in
"") scheduler="$SCHEDULER_DEFAULT" ;;
launchd | systemd | cron) ;;
*) die "--scheduler takes launchd, systemd, or cron, not '$scheduler'" ;;
esac

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

# --- The updater -----------------------------------------------------------------------

# A path is a usable copy of this script only if it is a file carrying the marker near the
# top. Under `curl ... | sh` $0 is the shell, not a file, so this is what decides whether
# the local copy can be copied or has to be fetched.
self_is_script() {
  [ -f "$1" ] && grep -q 'dmatrix-extensions-install-script' "$1" 2>/dev/null
}

# Puts the script the scheduled job will run at LOCAL_SCRIPT. The running file is used
# when there is one (a saved script, or the .pkg payload); the one-liner has no file, so
# the same ref the install used is fetched once, here, at install time. Whatever lands is
# what the job runs from then on: the job itself never fetches anything.
install_local_copy() {
  if [ "$dry_run" = 1 ]; then
    printf '  would run: %s\n' "install this script at ${LOCAL_SCRIPT}"
    return 0
  fi
  mkdir -p "$SUPPORT_DIR"
  if self_is_script "$0"; then
    cp "$0" "$LOCAL_SCRIPT"
  else
    raw="https://raw.githubusercontent.com/${REPO}/${REF}/install.sh"
    have curl || return 1
    curl -fsSL -o "${LOCAL_SCRIPT}.part" "$raw" || return 1
    if ! self_is_script "${LOCAL_SCRIPT}.part"; then
      rm -f "${LOCAL_SCRIPT}.part"
      return 1
    fi
    mv "${LOCAL_SCRIPT}.part" "$LOCAL_SCRIPT"
  fi
  chmod 0755 "$LOCAL_SCRIPT"
}

updater_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${UPDATER_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>${LOCAL_SCRIPT}</string>
    <string>--update</string>
  </array>
  <key>StartInterval</key>
  <integer>${UPDATER_INTERVAL}</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardErrorPath</key>
  <string>${LOG_FILE}</string>
</dict>
</plist>
PLIST
}

updater_service_unit() {
  cat <<UNIT
[Unit]
Description=Update the dMatrix plugin in every client that has it

[Service]
Type=oneshot
ExecStart=/bin/sh "${LOCAL_SCRIPT}" --update
UNIT
}

updater_timer_unit() {
  cat <<UNIT
[Unit]
Description=Daily dMatrix plugin update

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
UNIT
}

register_launchd() {
  if [ "$dry_run" = 1 ]; then
    printf '  would run: %s\n' "write ${PLIST_PATH}"
    printf '  would run: %s\n' "launchctl bootstrap gui/$(id -u) ${PLIST_PATH}"
    return 0
  fi
  mkdir -p "$(dirname "$PLIST_PATH")"
  updater_plist >"$PLIST_PATH"
  domain="gui/$(id -u)"
  launchctl bootout "${domain}/${UPDATER_LABEL}" 2>/dev/null || true
  # bootstrap is the supported call; load -w is the one older macOS answers to.
  launchctl bootstrap "$domain" "$PLIST_PATH" 2>/dev/null ||
    launchctl load -w "$PLIST_PATH" 2>/dev/null ||
    return 1
}

register_systemd() {
  if [ "$dry_run" = 1 ]; then
    printf '  would run: %s\n' "write ${SYSTEMD_DIR}/${UPDATER_UNIT}.service and .timer"
    printf '  would run: %s\n' "systemctl --user enable --now ${UPDATER_UNIT}.timer"
    return 0
  fi
  have systemctl || return 1
  mkdir -p "$SYSTEMD_DIR"
  updater_service_unit >"${SYSTEMD_DIR}/${UPDATER_UNIT}.service"
  updater_timer_unit >"${SYSTEMD_DIR}/${UPDATER_UNIT}.timer"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now "${UPDATER_UNIT}.timer" 2>/dev/null || return 1
}

# The crontab, rewritten with our one line: every other line the user has is preserved,
# and ours is replaced rather than duplicated on a re-run.
register_cron() {
  if [ "$dry_run" = 1 ]; then
    printf '  would run: %s\n' "add a daily crontab line running ${LOCAL_SCRIPT} --update"
    return 0
  fi
  have crontab || return 1
  existing="$(crontab -l 2>/dev/null | grep -v "$CRON_MARKER" || true)"
  {
    [ -z "$existing" ] || printf '%s\n' "$existing"
    printf '17 4 * * * /bin/sh "%s" --update %s\n' "$LOCAL_SCRIPT" "$CRON_MARKER"
  } | crontab - || return 1
}

register_updater() {
  if ! install_local_copy; then
    alert "updater — could not place a local copy at ${LOCAL_SCRIPT}; skipped"
    return 1
  fi
  case "$scheduler" in
  launchd) register_launchd || {
    alert "updater — could not register the LaunchAgent; re-run the one-liner to update"
    return 1
  } ;;
  systemd)
    if ! register_systemd; then
      # A desktop Linux without a user systemd instance is ordinary, so fall back
      # rather than leaving the install with no updater at all.
      register_cron || {
        alert "updater — neither a systemd timer nor a crontab entry could be registered"
        return 1
      }
      note "updater — daily crontab entry registered (no systemd user instance)"
      return 0
    fi
    ;;
  cron) register_cron || {
    alert "updater — could not add the crontab entry"
    return 1
  } ;;
  esac
  note "updater — daily ${scheduler} job registered; logs to ${LOG_FILE}"
}

remove_updater() {
  if [ "$dry_run" = 1 ]; then
    printf '  would run: %s\n' "unregister the ${scheduler} job and remove ${SUPPORT_DIR}"
    note "updater — removed"
    return 0
  fi
  if [ -f "$PLIST_PATH" ]; then
    launchctl bootout "gui/$(id -u)/${UPDATER_LABEL}" 2>/dev/null ||
      launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
  fi
  if [ -f "${SYSTEMD_DIR}/${UPDATER_UNIT}.timer" ]; then
    if have systemctl; then
      systemctl --user disable --now "${UPDATER_UNIT}.timer" 2>/dev/null || true
    fi
    rm -f "${SYSTEMD_DIR}/${UPDATER_UNIT}.timer" "${SYSTEMD_DIR}/${UPDATER_UNIT}.service"
    if have systemctl; then
      systemctl --user daemon-reload 2>/dev/null || true
    fi
  fi
  if have crontab && crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
    remaining="$(crontab -l 2>/dev/null | grep -v "$CRON_MARKER" || true)"
    if [ -z "$remaining" ]; then
      crontab -r 2>/dev/null || true
    else
      printf '%s\n' "$remaining" | crontab - 2>/dev/null || true
    fi
  fi
  rm -f "$LOCAL_SCRIPT" "$LOG_FILE"
  rmdir "$SUPPORT_DIR" 2>/dev/null || true
  note "updater — job, local copy, and log removed"
}

# Where a failed update has to end up for someone to see it. Best-effort by design: no
# notifier is a reason to leave the log behind, not to fail.
notify_failure() {
  if [ "$PLATFORM" = Darwin ] && have osascript; then
    osascript -e 'display notification "dMatrix could not update your plugins. See the log." with title "dMatrix"' \
      >/dev/null 2>&1 || true
  elif have notify-send; then
    notify-send "dMatrix" "Could not update your plugins. See ${LOG_FILE}" >/dev/null 2>&1 || true
  fi
  printf 'dMatrix update failed; see %s\n' "$LOG_FILE" >&2
}

# One client's update, for --update: the client's own commands and nothing else. Only
# called for a client that already has the plugin, so this never installs anywhere new.
update_claude() {
  claude plugin marketplace update "$MARKETPLACE" &&
    claude plugin update "$PLUGIN_ID" --scope user -y
}

update_codex() {
  codex plugin marketplace upgrade "$MARKETPLACE" &&
    codex plugin add "$PLUGIN_ID"
}

update_agy() {
  fetch_bundle && agy plugin install "${CACHE_DIR}/${BUNDLE_PATH}"
}

# The scheduled job's whole body. Silent on success: everything it says goes to the log,
# and only a failure reaches the user.
run_update() {
  mkdir -p "$SUPPORT_DIR"
  {
    printf '=== %s update (%s at %s) ===\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$REPO" "$REF"
    if have claude && claude_plugin_present; then
      if update_claude; then
        printf 'claude: updated\n'
      else
        printf 'claude: FAILED\n'
        n_fail=$((n_fail + 1))
      fi
    fi
    if have codex && codex_has_plugins && codex_plugin_present; then
      if update_codex; then
        printf 'codex: updated\n'
      else
        printf 'codex: FAILED\n'
        n_fail=$((n_fail + 1))
      fi
    fi
    if have agy && [ -d "$CACHE_DIR" ]; then
      if update_agy; then
        printf 'agy: updated\n'
      else
        printf 'agy: FAILED\n'
        n_fail=$((n_fail + 1))
      fi
    fi
  } >>"$LOG_FILE" 2>&1
  [ "$n_fail" = 0 ] || notify_failure
  # The job's exit status is what the scheduler records, so a failure stays visible there
  # as well as in the log.
  [ "$n_fail" = 0 ]
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
  case "$PLATFORM" in
  MINGW* | MSYS* | CYGWIN*)
    say "This is a Windows shell. Install with PowerShell instead:"
    say "  irm https://www.dmatrix.com/install.ps1 | iex"
    exit 1
    ;;
  esac

  # The scheduled job's mode: no banner, no summary, no per-client lines. It reports
  # through the log and, on failure, a notification.
  if [ "$update_mode" = 1 ]; then
    if run_update; then return 0; fi
    return 1
  fi

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
    # The updater belongs to the install as a whole, not to one client, so it goes only
    # when the run was not narrowed to a single client.
    if [ -z "$only" ]; then remove_updater || true; fi
    summary
    return 0
  fi

  say "Installing dMatrix from ${REPO} at ${REF}"
  if [ "$want_claude" = 1 ]; then install_claude || true; fi
  if [ "$want_codex" = 1 ]; then install_codex || true; fi
  if [ "$want_agy" = 1 ]; then install_agy || true; fi
  # Nothing to keep current if nothing was installed, and --no-updater opts out.
  if [ "$no_updater" = 0 ] && [ "$n_ok" -gt 0 ]; then register_updater || true; fi
  # Only mention the account-side surfaces when every detected client was handled; a run
  # narrowed with --only is answering a narrower question.
  if [ -z "$only" ]; then manual_steps; fi
  summary
  if [ "$n_ok" = 0 ]; then return 1; fi
}

main
