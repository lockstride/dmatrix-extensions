<#
    install.ps1 - install the dMatrix extensions plugin into every AI client on this machine.

        irm https://www.dmatrix.com/install.ps1 | iex
        $env:DMATRIX_DRY_RUN = 1; irm https://www.dmatrix.com/install.ps1 | iex

    This is the Windows half of the contract defined in install.sh's header, and it
    mirrors that contract exactly: the same clients, the same per-client commands, the
    same result lines, the same summary, the same exit codes. Change one, change both.
    Runs on Windows PowerShell 5.1 and PowerShell 7. No WSL.

    Options. `irm ... | iex` cannot pass parameters, so every option is accepted two
    ways - as a parameter when the script is saved and run as a file, and as an
    environment variable when it is piped into iex:

        -Only claude|codex|agy   DMATRIX_ONLY       one client instead of all detected
        -Ref <git-ref>           DMATRIX_REF        branch or tag (default: main)
        -DryRun                  DMATRIX_DRY_RUN    print what would happen, change nothing
        -Uninstall               DMATRIX_UNINSTALL  remove what this script installed
        -NoUpdater               DMATRIX_NO_UPDATER install without the daily updater
        -Update                  DMATRIX_UPDATE     the updater's own mode (see below)
        -Help                                       the usage text

    DMATRIX_EXTENSIONS_REPO and DMATRIX_EXTENSIONS_REF override where the plugin comes
    from, as in install.sh. A switch env var counts as set for 1, true, or yes.

    The updater. No client refreshes a third-party marketplace on its own, so an install
    also leaves a copy of this script under %LOCALAPPDATA%\dMatrix\ and registers a daily
    Task Scheduler task - current user, no elevation - that runs that local copy with
    -Update. -Update is quiet, touches only clients that already have the plugin, and runs
    nothing but those clients' own update commands: it never fetches code and executes it.
    Its output goes to a log beside the copy. A failure raises a notification, and because
    a notification can be suppressed, the next interactive run also prints the log's path.
    -NoUpdater skips all of it, and -Uninstall unregisters the task and removes the copy.

    Everything this file contains is ASCII on purpose: Windows PowerShell 5.1 decodes a
    .ps1 with no byte-order mark using the system's ANSI code page, which would mangle a
    literal non-ASCII character. The em dash the result lines carry is built from its
    code point at run time instead, so the output matches install.sh's exactly while the
    source stays portable.

    Exit codes:
        0  at least one client was installed or updated (or would be, under -DryRun)
        1  nothing could be installed - no supported client is on this machine, or
           every detected client failed
        2  the command line was wrong

    No elevation. Writes only under the clients' own homes and the cache dir, and is
    safe to re-run: a re-run updates every copy already installed.
#>

param(
    [string]$Only,
    [string]$Ref,
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$NoUpdater,
    [switch]$Update,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The result lines carry an em dash to match install.sh. Built from its code point so
# this file stays ASCII (see the header).
$script:Dash = [string][char]0x2014

# Best-effort: a console still on a legacy code page would render the em dash as a
# question mark. Nothing depends on it, so a host that refuses is not an error.
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
} catch {
    Write-Debug "console output encoding left as-is: $_"
}

function Test-EnvSwitch {
    param([string]$Value)
    if (-not $Value) { return $false }
    return @('1', 'true', 'yes') -contains $Value.Trim().ToLowerInvariant()
}

if (-not $Only -and $env:DMATRIX_ONLY) { $Only = $env:DMATRIX_ONLY }
if (-not $Ref -and $env:DMATRIX_REF) { $Ref = $env:DMATRIX_REF }
if (-not $Ref -and $env:DMATRIX_EXTENSIONS_REF) { $Ref = $env:DMATRIX_EXTENSIONS_REF }
if (-not $DryRun -and (Test-EnvSwitch $env:DMATRIX_DRY_RUN)) { $DryRun = $true }
if (-not $Uninstall -and (Test-EnvSwitch $env:DMATRIX_UNINSTALL)) { $Uninstall = $true }
if (-not $NoUpdater -and (Test-EnvSwitch $env:DMATRIX_NO_UPDATER)) { $NoUpdater = $true }
if (-not $Update -and (Test-EnvSwitch $env:DMATRIX_UPDATE)) { $Update = $true }

$script:Repo = if ($env:DMATRIX_EXTENSIONS_REPO) {
    $env:DMATRIX_EXTENSIONS_REPO
} else {
    'oxford-heavy/dmatrix-extensions'
}
$script:Ref = if ($Ref) { $Ref } else { 'main' }
$script:Marketplace = 'dmatrix-extensions'
$script:Plugin = 'dmatrix'
$script:PluginId = "$script:Plugin@$script:Marketplace"
# Where the Antigravity plugin bundle sits inside the repo archive.
$script:BundlePath = 'google/antigravity/dmatrix'

# %LOCALAPPDATA% on Windows; the XDG cache elsewhere, so a PowerShell 7 run on macOS or
# Linux lands in the same place install.sh uses.
$script:CacheRoot = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'dMatrix'
} elseif ($env:XDG_CACHE_HOME) {
    $env:XDG_CACHE_HOME
} else {
    Join-Path $HOME '.cache'
}
$script:CacheDir = Join-Path $script:CacheRoot 'dmatrix-extensions'

# The copy the scheduled task runs, and its log. Beside the cache under
# %LOCALAPPDATA%\dMatrix so an uninstall has one place to clear.
$script:LocalScript = Join-Path $script:CacheRoot 'install.ps1'
$script:LogFile = Join-Path $script:CacheRoot 'update.log'
$script:TaskName = 'dMatrixExtensionsUpdater'
# Task Scheduler and Register-ScheduledTask exist only on Windows; `$IsWindows` does not
# exist on Windows PowerShell 5.1, and Set-StrictMode makes reading it an error there.
$script:OnWindows = ($env:OS -eq 'Windows_NT')

$script:ClaudeManual = 'https://github.com/oxford-heavy/dmatrix-extensions/blob/main/claude/README.md'
$script:OpenAiManual = 'https://github.com/oxford-heavy/dmatrix-extensions/blob/main/openai/README.md'

$script:DryRunMode = [bool]$DryRun
$script:UninstallMode = [bool]$Uninstall
$script:UpdateMode = [bool]$Update
$script:CountOk = 0
$script:CountSkipped = 0
$script:CountFailed = 0

# Console writes rather than Write-Output: a result line must never leak into a
# function's return value, and Write-Host is what PSScriptAnalyzer rejects. Under -Update
# there is no console worth writing to - the scheduled task discards it - so the same lines
# go to the log, which is the run's only record.
function Write-Line {
    param([string]$Text = '')
    if ($script:UpdateMode) {
        try {
            Add-Content -LiteralPath $script:LogFile -Value $Text
        } catch {
            Write-Debug "could not append to the log: $_"
        }
        return
    }
    [Console]::Out.WriteLine($Text)
}

function Write-ErrLine {
    param([string]$Text)
    [Console]::Error.WriteLine($Text)
}

function Write-Note {
    param([string]$Text)
    Write-Line "  --    $Text"
}

function Write-Ok {
    param([string]$Text)
    Write-Line "  ok    $Text"
    $script:CountOk++
}

function Write-Skipped {
    param([string]$Text)
    Write-Line "  --    $Text"
    $script:CountSkipped++
}

function Write-Failure {
    param([string]$Text)
    Write-ErrLine "  warn  $Text"
    $script:CountFailed++
}

# A warning about something that is not one of the clients - the updater. Shaped like a
# client warning so it reads the same, but outside the counts, which are per client.
function Write-Alert {
    param([string]$Text)
    Write-ErrLine "  warn  $Text"
}

function Show-Usage {
    Write-Line 'Usage: install.ps1 [-Only claude|codex|agy] [-Ref <git-ref>] [-DryRun] [-Uninstall]'
    Write-Line ''
    Write-Line 'Installs the dMatrix plugin into every AI client found on this machine, each'
    Write-Line 'through its own plugin manager: Claude Code, Codex CLI (which also covers the'
    Write-Line 'ChatGPT desktop app), and Antigravity CLI. Prints one result line per client.'
    Write-Line 'Safe to re-run - a re-run updates every copy already installed.'
    Write-Line ''
    Write-Line '  -Only claude|codex|agy   one client instead of every client detected'
    Write-Line '  -Ref <git-ref>           branch or tag to install from (default: main)'
    Write-Line '  -DryRun                  print what would happen without changing anything'
    Write-Line '  -Uninstall               remove what this script installed, updater included'
    Write-Line '  -NoUpdater               install without the daily updater'
    Write-Line '  -Update                  what the updater runs: quiet, installed clients only'
    Write-Line '  -Help                    this text'
    Write-Line ''
    Write-Line 'Piping into iex passes no parameters, so each option is also read from an'
    Write-Line 'environment variable: DMATRIX_ONLY, DMATRIX_REF, DMATRIX_DRY_RUN,'
    Write-Line 'DMATRIX_UNINSTALL, DMATRIX_NO_UPDATER, DMATRIX_UPDATE.'
    Write-Line ''
    Write-Line 'An install also registers a daily scheduled task that re-runs the clients own'
    Write-Line 'update commands, so a new release reaches every installed client without you'
    Write-Line 'doing anything. It runs a copy of this script kept beside its log, and never'
    Write-Line 'fetches code to execute.'
    Write-Line ''
    Write-Line 'The Claude app (including Cowork), claude.ai, and ChatGPT on the web install'
    Write-Line 'against your account and cannot be scripted; this prints their manual steps.'
    Write-Line ''
    Write-Line 'On macOS and Linux, use install.sh:  curl -fsSL https://www.dmatrix.com/install.sh | sh'
}

function Test-ClientPresent {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

<#
    Appends the Machine and User PATH that Windows has saved to this process's PATH. A
    process can start without them: the MSI's custom action is launched by the Windows
    Installer service, which never had the user's PATH, and a terminal opened before a
    client was installed predates that client's entry. Appended, so a caller's own PATH
    still wins. Nothing is saved outside Windows, where this does nothing.
#>
function Add-SavedPath {
    $separator = [IO.Path]::PathSeparator
    $current = @($env:PATH -split $separator)
    foreach ($scope in @('Machine', 'User')) {
        $saved = [Environment]::GetEnvironmentVariable('PATH', $scope)
        if (-not $saved) { continue }
        foreach ($entry in $saved -split $separator) {
            $entry = [Environment]::ExpandEnvironmentVariables($entry)
            if ($entry -and $current -notcontains $entry) {
                $env:PATH = "$env:PATH$separator$entry"
                $current += $entry
            }
        }
    }
}

<#
    Runs one client command, or prints it under -DryRun. Returns whether it succeeded,
    and nothing else: the command's own output is captured and re-emitted through
    Write-Line so it cannot end up in this function's return value. Always succeeds in a
    dry run, so the result lines and the exit code match a real run's.
#>
function Invoke-ClientCommand {
    param(
        [string]$Exe,
        [string[]]$Arguments
    )
    if ($script:DryRunMode) {
        Write-Line ("  would run: {0} {1}" -f $Exe, ($Arguments -join ' '))
        return $true
    }
    $output = & $Exe @Arguments 2>&1
    $succeeded = ($LASTEXITCODE -eq 0)
    foreach ($line in @($output)) {
        if ($null -ne $line) { Write-Line ([string]$line) }
    }
    return $succeeded
}

# Reads a client's own listing. Read-only, so it runs under -DryRun too.
function Get-ClientOutput {
    param(
        [string]$Exe,
        [string[]]$Arguments
    )
    try {
        $output = & $Exe @Arguments 2>$null
    } catch {
        return ''
    }
    return (@($output) -join "`n")
}

# --- Claude Code ----------------------------------------------------------------------

function Test-ClaudeMarketplace {
    $listing = Get-ClientOutput 'claude' @('plugin', 'marketplace', 'list', '--json')
    return $listing -match ('"' + [regex]::Escape($script:Marketplace) + '"')
}

function Test-ClaudePlugin {
    $listing = Get-ClientOutput 'claude' @('plugin', 'list', '--json')
    return $listing -match ('"' + [regex]::Escape($script:PluginId) + '"')
}

# What `claude plugin marketplace add` is given: the bare repo for the default branch,
# and the git URL with a ref fragment when -Ref pins one.
function Get-ClaudeSource {
    if ($script:Ref -eq 'main') { return $script:Repo }
    return "https://github.com/$script:Repo.git#$script:Ref"
}

function Install-ForClaude {
    if (Test-ClaudeMarketplace) {
        if (-not (Invoke-ClientCommand 'claude' @('plugin', 'marketplace', 'update', $script:Marketplace))) {
            Write-Failure "Claude Code $script:Dash could not refresh the $script:Marketplace marketplace"
            return $false
        }
    } else {
        if (-not (Invoke-ClientCommand 'claude' @('plugin', 'marketplace', 'add', (Get-ClaudeSource)))) {
            Write-Failure "Claude Code $script:Dash could not add the $script:Marketplace marketplace"
            return $false
        }
    }
    if (Test-ClaudePlugin) {
        if (-not (Invoke-ClientCommand 'claude' @('plugin', 'update', $script:PluginId, '--scope', 'user', '-y'))) {
            Write-Failure "Claude Code $script:Dash could not update $script:PluginId"
            return $false
        }
        Write-Ok "Claude Code $script:Dash updated $script:PluginId at user scope"
    } else {
        if (-not (Invoke-ClientCommand 'claude' @('plugin', 'install', $script:PluginId, '--scope', 'user', '-y'))) {
            Write-Failure "Claude Code $script:Dash could not install $script:PluginId"
            return $false
        }
        Write-Ok "Claude Code $script:Dash installed $script:PluginId at user scope"
    }
    Write-Note "Claude Code $script:Dash new sessions load it; in an open session run /reload-plugins"
    return $true
}

function Uninstall-ForClaude {
    if (Test-ClaudePlugin) {
        if (-not (Invoke-ClientCommand 'claude' @('plugin', 'uninstall', $script:PluginId, '--scope', 'user', '-y'))) {
            Write-Failure "Claude Code $script:Dash could not uninstall $script:PluginId"
            return $false
        }
        Write-Ok "Claude Code $script:Dash uninstalled $script:PluginId"
    } else {
        Write-Skipped "Claude Code $script:Dash $script:PluginId is not installed"
    }
    if (Test-ClaudeMarketplace) {
        if (-not (Invoke-ClientCommand 'claude' @('plugin', 'marketplace', 'remove', $script:Marketplace))) {
            Write-Failure "Claude Code $script:Dash could not remove the $script:Marketplace marketplace"
        }
    }
    return $true
}

# --- Codex CLI (and the ChatGPT desktop app) -------------------------------------------

function Test-CodexPluginSupport {
    $null = Get-ClientOutput 'codex' @('plugin', '--help')
    return ($LASTEXITCODE -eq 0)
}

function Test-CodexMarketplace {
    $listing = Get-ClientOutput 'codex' @('plugin', 'marketplace', 'list')
    return $listing -match ('(?m)^' + [regex]::Escape($script:Marketplace) + '\s')
}

# The table's STATUS column reads "installed, enabled" for an installed plugin and
# "not installed" otherwise, so anchoring on "installed" after the id distinguishes them.
function Test-CodexPlugin {
    $listing = Get-ClientOutput 'codex' @('plugin', 'list')
    return $listing -match ('(?m)^' + [regex]::Escape($script:PluginId) + '\s+installed')
}

function Install-ForCodex {
    if (-not (Test-CodexPluginSupport)) {
        Write-Failure "Codex CLI $script:Dash this version has no plugin commands; update Codex and re-run"
        return $false
    }
    if (Test-CodexMarketplace) {
        if (-not (Invoke-ClientCommand 'codex' @('plugin', 'marketplace', 'upgrade', $script:Marketplace))) {
            Write-Failure "Codex CLI $script:Dash could not refresh the $script:Marketplace marketplace"
            return $false
        }
    } else {
        $addArgs = @('plugin', 'marketplace', 'add', $script:Repo)
        if ($script:Ref -ne 'main') { $addArgs += @('--ref', $script:Ref) }
        if (-not (Invoke-ClientCommand 'codex' $addArgs)) {
            Write-Failure "Codex CLI $script:Dash could not add the $script:Marketplace marketplace"
            return $false
        }
    }
    $had = Test-CodexPlugin
    if (-not (Invoke-ClientCommand 'codex' @('plugin', 'add', $script:PluginId))) {
        Write-Failure "Codex CLI $script:Dash could not install $script:PluginId"
        return $false
    }
    if ($had) {
        Write-Ok "Codex CLI $script:Dash updated $script:PluginId"
    } else {
        Write-Ok "Codex CLI $script:Dash installed $script:PluginId"
    }
    Write-Note "Codex CLI $script:Dash new sessions load it; restart the ChatGPT desktop app to pick it up"
    return $true
}

function Uninstall-ForCodex {
    if (-not (Test-CodexPluginSupport)) {
        Write-Failure "Codex CLI $script:Dash this version has no plugin commands; nothing to remove"
        return $false
    }
    if (Test-CodexPlugin) {
        if (-not (Invoke-ClientCommand 'codex' @('plugin', 'remove', $script:PluginId))) {
            Write-Failure "Codex CLI $script:Dash could not uninstall $script:PluginId"
            return $false
        }
        Write-Ok "Codex CLI $script:Dash uninstalled $script:PluginId"
    } else {
        Write-Skipped "Codex CLI $script:Dash $script:PluginId is not installed"
    }
    if (Test-CodexMarketplace) {
        if (-not (Invoke-ClientCommand 'codex' @('plugin', 'marketplace', 'remove', $script:Marketplace))) {
            Write-Failure "Codex CLI $script:Dash could not remove the $script:Marketplace marketplace"
        }
    }
    return $true
}

# --- Antigravity CLI -------------------------------------------------------------------

<#
    Antigravity installs a plugin from a directory, not a marketplace, so the bundle has
    to be on disk first. The cache dir is replaced on every run, which is what makes a
    re-run an update.
#>
function Get-ExtensionsBundle {
    $archiveUrl = "https://github.com/$script:Repo/archive/$script:Ref.tar.gz"
    $tarball = "$script:CacheDir.tar.gz"
    if ($script:DryRunMode) {
        Write-Line "  would run: Invoke-WebRequest -Uri $archiveUrl -OutFile $tarball"
        Write-Line "  would run: tar -xzf $tarball --strip-components=1 -C $script:CacheDir"
        return $true
    }
    try {
        if (Test-Path -LiteralPath $script:CacheDir) {
            Remove-Item -LiteralPath $script:CacheDir -Recurse -Force
        }
        $null = New-Item -ItemType Directory -Path $script:CacheDir -Force
        Invoke-WebRequest -Uri $archiveUrl -OutFile $tarball -UseBasicParsing
        & tar -xzf $tarball '--strip-components=1' '-C' $script:CacheDir
        $extracted = ($LASTEXITCODE -eq 0)
        Remove-Item -LiteralPath $tarball -Force -ErrorAction SilentlyContinue
        return $extracted
    } catch {
        Write-Debug "bundle fetch failed: $_"
        Remove-Item -LiteralPath $tarball -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Install-ForAntigravity {
    if (-not (Get-ExtensionsBundle)) {
        Write-Failure "Antigravity CLI $script:Dash could not fetch $script:Repo at $script:Ref"
        return $false
    }
    $bundle = Join-Path $script:CacheDir ($script:BundlePath -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Invoke-ClientCommand 'agy' @('plugin', 'install', $bundle))) {
        Write-Failure "Antigravity CLI $script:Dash could not install $script:Plugin"
        return $false
    }
    Write-Ok "Antigravity CLI $script:Dash installed $script:Plugin from the fetched bundle"
    Write-Note "Antigravity CLI $script:Dash restart agy, then check /skills and /mcp"
    return $true
}

function Uninstall-ForAntigravity {
    # Antigravity's removal command is the one step in this script that no dMatrix
    # release has exercised on a real install, so a failure here is reported as a manual
    # step rather than treated as the client failing.
    if (Invoke-ClientCommand 'agy' @('plugin', 'uninstall', $script:Plugin)) {
        Write-Ok "Antigravity CLI $script:Dash uninstalled $script:Plugin"
    } else {
        Write-Note "Antigravity CLI $script:Dash 'agy plugin uninstall $script:Plugin' failed; remove it by hand"
        Write-Note "Antigravity CLI $script:Dash check 'agy plugin list' for the name it is registered under"
        $script:CountSkipped++
    }
    if ($script:DryRunMode) {
        Write-Line "  would run: Remove-Item -Recurse -Force $script:CacheDir"
    } elseif (Test-Path -LiteralPath $script:CacheDir) {
        Remove-Item -LiteralPath $script:CacheDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $true
}

# --- The updater -----------------------------------------------------------------------

# A path is a usable copy of this script only if it is a file carrying the marker in its
# header. Piped into iex there is no file at all, so this is what decides whether the local
# copy can be copied or has to be fetched.
function Test-SelfScript {
    param([string]$Path)
    if (-not $Path) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return (Get-Content -LiteralPath $Path -Raw) -match 'dmatrix-extensions-install-script'
}

<#
    Puts the script the scheduled task will run at $script:LocalScript. The running file is
    used when there is one (a saved script, or the MSI payload); the `| iex` path has no
    file, so the same ref the install used is fetched once, here, at install time. Whatever
    lands is what the task runs from then on: the task itself never fetches anything.

    The running file can already *be* $script:LocalScript - the MSI lays its payload down in
    %LOCALAPPDATA%\dMatrix, which is exactly where the copy belongs - and copying a file
    onto itself is an error rather than a no-op. Already in place is the copy installed.
#>
function Install-LocalCopy {
    if ($script:DryRunMode) {
        Write-Line "  would run: install this script at $script:LocalScript"
        return $true
    }
    try {
        $null = New-Item -ItemType Directory -Path $script:CacheRoot -Force
        $running = $PSCommandPath
        if (Test-SelfScript $running) {
            $already = ([IO.Path]::GetFullPath($running) -eq
                [IO.Path]::GetFullPath($script:LocalScript))
            if (-not $already) {
                Copy-Item -LiteralPath $running -Destination $script:LocalScript -Force
            }
            return $true
        }
        $raw = "https://raw.githubusercontent.com/$script:Repo/$script:Ref/install.ps1"
        $part = "$script:LocalScript.part"
        Invoke-WebRequest -Uri $raw -OutFile $part -UseBasicParsing
        if (-not (Test-SelfScript $part)) {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            return $false
        }
        Move-Item -LiteralPath $part -Destination $script:LocalScript -Force
        return $true
    } catch {
        Write-Debug "local copy failed: $_"
        return $false
    }
}

<#
    Registers the daily task. `powershell.exe` rather than the engine that happens to be
    running: Windows PowerShell is always present, so the task keeps working if a
    side-by-side PowerShell 7 is later removed. -Force replaces an existing registration,
    which is what makes a re-run an update rather than a duplicate.
#>
function Register-Updater {
    if (-not (Install-LocalCopy)) {
        Write-Alert "updater $script:Dash could not place a local copy at $script:LocalScript; skipped"
        return $false
    }
    if (-not $script:OnWindows) {
        Write-Note "updater $script:Dash not registered: Task Scheduler is Windows-only (use install.sh here)"
        return $true
    }
    if ($script:DryRunMode) {
        Write-Line "  would run: Register-ScheduledTask -TaskName $script:TaskName (daily, current user)"
        Write-Note "updater $script:Dash daily scheduled task registered; logs to $script:LogFile"
        return $true
    }
    try {
        $argument = "-NoProfile -ExecutionPolicy Bypass -File `"$script:LocalScript`" -Update"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
        $trigger = New-ScheduledTaskTrigger -Daily -At '4:17am'
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $null = Register-ScheduledTask -TaskName $script:TaskName -Action $action `
            -Trigger $trigger -Settings $settings -Force `
            -Description 'Updates the dMatrix plugin in every client that has it.'
    } catch {
        Write-Alert "updater $script:Dash could not register the scheduled task: $_"
        return $false
    }
    Write-Note "updater $script:Dash daily scheduled task registered; logs to $script:LogFile"
    return $true
}

function Unregister-Updater {
    if ($script:DryRunMode) {
        Write-Line "  would run: Unregister-ScheduledTask -TaskName $script:TaskName"
        Write-Line "  would run: Remove-Item -Recurse -Force $script:CacheRoot"
        Write-Note "updater $script:Dash removed"
        return $true
    }
    if ($script:OnWindows) {
        try {
            $existing = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
            if ($existing) {
                Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
            }
        } catch {
            Write-Alert "updater $script:Dash could not unregister the scheduled task: $_"
        }
    }
    foreach ($path in @($script:LocalScript, $script:LogFile)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Note "updater $script:Dash task, local copy, and log removed"
    return $true
}

<#
    Where a failed update has to end up for someone to see it. A tray balloon is the only
    notifier every supported Windows has without extra modules, and it can be suppressed by
    policy - so the log is the durable record and Show-UpdateFailure surfaces it on the next
    interactive run. Best-effort by design: no notifier is a reason to keep the log, not to
    fail.
#>
function Show-Notification {
    param([string]$Message)
    if (-not $script:OnWindows) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $icon = New-Object System.Windows.Forms.NotifyIcon
        $icon.Icon = [System.Drawing.SystemIcons]::Warning
        $icon.BalloonTipTitle = 'dMatrix'
        $icon.BalloonTipText = $Message
        $icon.Visible = $true
        $icon.ShowBalloonTip(10000)
        Start-Sleep -Seconds 1
        $icon.Dispose()
    } catch {
        Write-Debug "notification unavailable: $_"
    }
}

# The second half of "failures surface where the user will see them": if the last run the
# log recorded failed, say so the next time someone runs this interactively.
function Show-UpdateFailure {
    if (-not (Test-Path -LiteralPath $script:LogFile)) { return }
    try {
        $sessions = (Get-Content -LiteralPath $script:LogFile -Raw) -split '(?m)^=== '
        $last = @($sessions)[-1]
    } catch {
        return
    }
    if ($last -match 'FAILED') {
        Write-Alert "updater $script:Dash the last automatic update failed; see $script:LogFile"
    }
}

# One client's update: the client's own commands and nothing else. Only called for a client
# that already has the plugin, so this never installs anywhere new.
function Invoke-ClaudeUpdate {
    if (-not (Invoke-ClientCommand 'claude' @('plugin', 'marketplace', 'update', $script:Marketplace))) {
        return $false
    }
    return (Invoke-ClientCommand 'claude' @('plugin', 'update', $script:PluginId, '--scope', 'user', '-y'))
}

function Invoke-CodexUpdate {
    if (-not (Invoke-ClientCommand 'codex' @('plugin', 'marketplace', 'upgrade', $script:Marketplace))) {
        return $false
    }
    return (Invoke-ClientCommand 'codex' @('plugin', 'add', $script:PluginId))
}

function Invoke-AntigravityUpdate {
    if (-not (Get-ExtensionsBundle)) { return $false }
    $bundle = Join-Path $script:CacheDir ($script:BundlePath -replace '/', [IO.Path]::DirectorySeparatorChar)
    return (Invoke-ClientCommand 'agy' @('plugin', 'install', $bundle))
}

<#
    The scheduled task's whole body. Silent on success: everything it says goes to the log,
    and only a failure reaches the user. Returns whether every client it tried succeeded,
    which becomes the task's recorded exit status.
#>
function Invoke-Update {
    $null = New-Item -ItemType Directory -Path $script:CacheRoot -Force
    Write-Line ("=== {0} update ({1} at {2}) ===" -f
        (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'),
        $script:Repo, $script:Ref)
    $failed = 0
    if ((Test-ClientPresent 'claude') -and (Test-ClaudePlugin)) {
        if (Invoke-ClaudeUpdate) {
            Write-Line 'claude: updated'
        } else {
            Write-Line 'claude: FAILED'
            $failed++
        }
    }
    if ((Test-ClientPresent 'codex') -and (Test-CodexPluginSupport) -and (Test-CodexPlugin)) {
        if (Invoke-CodexUpdate) {
            Write-Line 'codex: updated'
        } else {
            Write-Line 'codex: FAILED'
            $failed++
        }
    }
    if ((Test-ClientPresent 'agy') -and (Test-Path -LiteralPath $script:CacheDir)) {
        if (Invoke-AntigravityUpdate) {
            Write-Line 'agy: updated'
        } else {
            Write-Line 'agy: FAILED'
            $failed++
        }
    }
    if ($failed -gt 0) {
        Show-Notification "Could not update your dMatrix plugins. See $script:LogFile"
        Write-ErrLine "dMatrix update failed; see $script:LogFile"
        return $false
    }
    return $true
}

# --- Manual surfaces -------------------------------------------------------------------

function Show-ManualPointer {
    Write-Line ''
    Write-Line 'Three surfaces install against your account, not this machine, so they take a few'
    Write-Line 'clicks each. Their steps:'
    Write-Line "  The Claude app and claude.ai:  $script:ClaudeManual"
    Write-Line "  ChatGPT on the web:            $script:OpenAiManual"
}

# --- Main ------------------------------------------------------------------------------

function Show-Summary {
    Write-Line ''
    if ($script:DryRunMode) {
        Write-Line 'Dry run: nothing was changed.'
    }
    if ($script:UninstallMode) {
        Write-Line ("Done. {0} removed, {1} skipped, {2} failed." -f
            $script:CountOk, $script:CountSkipped, $script:CountFailed)
    } else {
        Write-Line ("Done. {0} installed or updated, {1} skipped, {2} failed." -f
            $script:CountOk, $script:CountSkipped, $script:CountFailed)
    }
}

if ($Help) {
    Show-Usage
    exit 0
}

Add-SavedPath

# The scheduled task's mode: no banner, no summary, no per-client lines. It reports through
# the log and, on failure, a notification.
if ($script:UpdateMode) {
    if (Invoke-Update) { exit 0 }
    exit 1
}

if ($Only -and @('claude', 'codex', 'agy') -notcontains $Only) {
    Write-ErrLine "error: -Only takes claude, codex, or agy, not '$Only'"
    exit 2
}

$wantClaude = (-not $Only -or $Only -eq 'claude') -and (Test-ClientPresent 'claude')
$wantCodex = (-not $Only -or $Only -eq 'codex') -and (Test-ClientPresent 'codex')
$wantAgy = (-not $Only -or $Only -eq 'agy') -and (Test-ClientPresent 'agy')

# An uninstall still has work to do when no client is on PATH - the updater's task, its
# local copy and its log are machine-level, not per client - so it runs ahead of the
# guards, which only make sense for an install.
if ($script:UninstallMode) {
    Write-Line 'Removing dMatrix'
    if ($wantClaude) { $null = Uninstall-ForClaude }
    if ($wantCodex) { $null = Uninstall-ForCodex }
    if ($wantAgy) { $null = Uninstall-ForAntigravity }
    # One task serves every client and an install registers it whatever -Only says, so
    # every uninstall removes it.
    $null = Unregister-Updater
    Show-Summary
    exit 0
}

if (-not ($wantClaude -or $wantCodex -or $wantAgy)) {
    if ($Only) {
        Write-Line "'$Only' is not on PATH, so there is nothing to do."
    } else {
        Write-Line 'No supported client is on PATH (looked for claude, codex, agy).'
        Write-Line 'Install one of them and re-run, or follow the manual steps:'
        Write-Line "  The Claude app and claude.ai:  $script:ClaudeManual"
        Write-Line "  ChatGPT on the web:            $script:OpenAiManual"
    }
    exit 1
}

Write-Line "Installing dMatrix from $script:Repo at $script:Ref"
Show-UpdateFailure
if ($wantClaude) { $null = Install-ForClaude }
if ($wantCodex) { $null = Install-ForCodex }
if ($wantAgy) { $null = Install-ForAntigravity }
# Nothing to keep current if nothing was installed, and -NoUpdater opts out.
if (-not $NoUpdater -and $script:CountOk -gt 0) { $null = Register-Updater }
# Only mention the account-side surfaces when every detected client was handled; a run
# narrowed with -Only is answering a narrower question.
if (-not $Only) { Show-ManualPointer }
Show-Summary
if ($script:CountOk -eq 0) { exit 1 }
exit 0
