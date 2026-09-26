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
        -Help                                       the usage text

    DMATRIX_EXTENSIONS_REPO and DMATRIX_EXTENSIONS_REF override where the plugin comes
    from, as in install.sh. A switch env var counts as set for 1, true, or yes.

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

$script:Repo = if ($env:DMATRIX_EXTENSIONS_REPO) {
    $env:DMATRIX_EXTENSIONS_REPO
} else {
    'lockstride/dmatrix-extensions'
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

$script:ClaudeManual = 'https://github.com/lockstride/dmatrix-extensions/blob/main/claude/README.md'
$script:OpenAiManual = 'https://github.com/lockstride/dmatrix-extensions/blob/main/openai/README.md'

$script:DryRunMode = [bool]$DryRun
$script:UninstallMode = [bool]$Uninstall
$script:CountOk = 0
$script:CountSkipped = 0
$script:CountFailed = 0

# Console writes rather than Write-Output: a result line must never leak into a
# function's return value, and Write-Host is what PSScriptAnalyzer rejects.
function Write-Line {
    param([string]$Text = '')
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
    Write-Line '  -Uninstall               remove what this script installed'
    Write-Line '  -Help                    this text'
    Write-Line ''
    Write-Line 'Piping into iex passes no parameters, so each option is also read from an'
    Write-Line 'environment variable: DMATRIX_ONLY, DMATRIX_REF, DMATRIX_DRY_RUN,'
    Write-Line 'DMATRIX_UNINSTALL.'
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

if ($Only -and @('claude', 'codex', 'agy') -notcontains $Only) {
    Write-ErrLine "error: -Only takes claude, codex, or agy, not '$Only'"
    exit 2
}

$wantClaude = (-not $Only -or $Only -eq 'claude') -and (Test-ClientPresent 'claude')
$wantCodex = (-not $Only -or $Only -eq 'codex') -and (Test-ClientPresent 'codex')
$wantAgy = (-not $Only -or $Only -eq 'agy') -and (Test-ClientPresent 'agy')

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

if ($script:UninstallMode) {
    Write-Line 'Removing dMatrix'
    if ($wantClaude) { $null = Uninstall-ForClaude }
    if ($wantCodex) { $null = Uninstall-ForCodex }
    if ($wantAgy) { $null = Uninstall-ForAntigravity }
    Show-Summary
    exit 0
}

Write-Line "Installing dMatrix from $script:Repo at $script:Ref"
if ($wantClaude) { $null = Install-ForClaude }
if ($wantCodex) { $null = Install-ForCodex }
if ($wantAgy) { $null = Install-ForAntigravity }
# Only mention the account-side surfaces when every detected client was handled; a run
# narrowed with -Only is answering a narrower question.
if (-not $Only) { Show-ManualPointer }
Show-Summary
if ($script:CountOk -eq 0) { exit 1 }
exit 0
