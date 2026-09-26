<#
    build-msi.ps1 - build dmatrix.msi, the Windows installer, unsigned.

        pnpm extensions:build:msi
        pwsh -File installers/windows/build-msi.ps1 -Script install.ps1

    The installer's payload is install.ps1 itself - the same file `irm ... | iex` runs, not a
    copy of its logic - laid down in %LOCALAPPDATA%\dMatrix and run by a custom action.
    Everything the installer does, the script does.

    Parameters:
        -Script <path>   the install.ps1 to package (default: ./install.ps1)
        -Version <v>     the installer version (default: read from the sources below)
        -Out <path>      where to write the MSI (default: dist/installers/dmatrix.msi)

    The version defaults to PLUGIN_VERSION, read from
    packages/canonical-prompt/src/version.ts in this repo or .claude-plugin/plugin.json in
    the rendered extensions repo, so the installer version and the plugin version are the
    same number by construction.

    Needs the .NET SDK. The WiX toolset is pinned in .config/dotnet-tools.json beside this
    script and restored on demand, so the build is reproducible from a clean machine.

    Signing is not done here. The release workflow signs when the signing secrets are
    present; until then what this produces is what ships (DMA-204).
#>

param(
    [string]$Script,
    [string]$Version,
    [string]$Out
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Script) { $Script = 'install.ps1' }
if (-not $Out) { $Out = Join-Path 'dist' (Join-Path 'installers' 'dmatrix.msi') }

# The first version-looking value in a JSON or TS source is PLUGIN_VERSION in both layouts.
# Case-insensitive: it is `PLUGIN_VERSION` in the TypeScript and `"version"` in the JSON.
function Read-SourceVersion {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $match = [regex]::Match(
        (Get-Content -LiteralPath $Path -Raw),
        'version["\s]*[:=]\s*"(\d[^"]*)"',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

if (-not $Version) {
    foreach ($candidate in @(
            (Join-Path 'packages' (Join-Path 'canonical-prompt' (Join-Path 'src' 'version.ts'))),
            (Join-Path '.claude-plugin' 'plugin.json'))) {
        $Version = Read-SourceVersion $candidate
        if ($Version) { break }
    }
}
if (-not $Version) {
    throw 'could not determine the version; pass -Version'
}
if (-not (Test-Path -LiteralPath $Script -PathType Leaf)) {
    throw "no install script at $Script"
}
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'the .NET SDK is required to build the MSI (dotnet is not on PATH)'
}

$payloadDir = (Resolve-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Script))).Path
$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    $null = New-Item -ItemType Directory -Path $outDir -Force
}

# The pinned toolset, restored from the manifest beside this script rather than whatever
# happens to be installed globally.
Push-Location $here
try {
    dotnet tool restore
    if ($LASTEXITCODE -ne 0) { throw "dotnet tool restore failed ($LASTEXITCODE)" }
    # -g keeps the extension cache in the user profile. Without it wix writes a .wix/
    # directory beside these sources, which the renderer would then copy into the
    # extensions repo as if it were a source file.
    foreach ($extension in @('WixToolset.UI.wixext/5.0.2', 'WixToolset.Util.wixext/5.0.2')) {
        dotnet wix extension add -g $extension
        if ($LASTEXITCODE -ne 0) { throw "could not add the WiX extension $extension" }
    }
} finally {
    Pop-Location
}

$outFull = if ([IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path (Get-Location).Path $Out }

Push-Location $here
try {
    dotnet wix build `
        -arch x64 `
        -define "Version=$Version" `
        -bindpath "payload=$payloadDir" `
        -ext WixToolset.UI.wixext `
        -ext WixToolset.Util.wixext `
        -out $outFull `
        'dmatrix.wxs'
    if ($LASTEXITCODE -ne 0) {
        # WiX says so itself on a non-Windows host ("The WiX Toolset only supports
        # Windows... All behavior after this point is undefined") and then rejects the
        # install directory's name as not relative, whatever it is. Nothing in the sources
        # is wrong; the toolset simply cannot finish here. The windows-latest job in
        # .github/workflows/installers.yml is where the MSI is actually built and tested.
        if ($env:OS -ne 'Windows_NT') {
            throw "wix build failed ($LASTEXITCODE). The WiX toolset only builds on Windows - " +
                'compile errors above may be that limitation rather than a problem with dmatrix.wxs.'
        }
        throw "wix build failed ($LASTEXITCODE)"
    }
} finally {
    Pop-Location
}

Write-Output "built $Out ($Version, unsigned)"
