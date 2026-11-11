#Requires -Version 7.4
<#
Downloads the prebuilt SDL3 libraries that match the committed bindings into lib/<os>-<arch>/, from the GitHub release named
in upstream/release.env (written by .github/workflows/build-sdl3.yml). The PowerShell version of tools/fetch_sdl3_libs.sh.

Usage: tools/fetch_sdl3_libs.ps1 [PLATFORM...]
  PLATFORM  windows-x86_64, linux-x86_64 or macos-arm64 (default: this machine's)

Checks that the release was built from the committed SDL version and build options, and the downloads against the release's
SHA256SUMS. Uses gh when it is installed and logged in, else Invoke-WebRequest.
Environment:
  SDL3_RELEASE_REPO  (default: mpalomas/sdl3_odin)
  SDL3_RELEASE_URL   Base URL of the release downloads, without gh (default: the repository's releases)
#>
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Platforms
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$Repo = Split-Path -Parent $PSScriptRoot
$Slug = $env:SDL3_RELEASE_REPO ? $env:SDL3_RELEASE_REPO : 'mpalomas/sdl3_odin'
$BaseUrl = $env:SDL3_RELEASE_URL ? $env:SDL3_RELEASE_URL : "https://github.com/$Slug/releases/download"
$Pin = Join-Path $Repo 'upstream/release.env'

$Tag = (Select-String -Path $Pin -Pattern '^RELEASE_TAG=(.+)$').Matches.Groups[1].Value
if (-not $Tag) { throw "no RELEASE_TAG in ${Pin}: no release has these sources yet. Build the libraries with tools/build_sdl3.ps1" }

if (-not $Platforms) {
    $os = $IsWindows ? 'windows' : $IsMacOS ? 'macos' : $IsLinux ? 'linux' : (throw 'unsupported OS')
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64' { 'x86_64' }
        'Arm64' { 'arm64' }
        default { throw "unsupported architecture $_" }
    }
    $Platforms = @("$os-$arch")
}

$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) "sdl3_libs_$PID"
New-Item -ItemType Directory -Force $Tmp | Out-Null
try {
    $files = @('sources.env', 'sdl3_options.cmake', 'SHA256SUMS') + ($Platforms | ForEach-Object { "sdl3-$_.tar.gz" })

    Write-Host "Downloading $($files -join ' ') from release $Tag of $Slug"
    $gh = -not $env:SDL3_RELEASE_URL -and (Get-Command gh -ErrorAction SilentlyContinue)
    if ($gh) {
        try { gh auth status 2>&1 | Out-Null } catch { $gh = $false }
    }
    if ($gh) {
        gh release download $Tag --repo $Slug --dir $Tmp @($files | ForEach-Object { '--pattern', $_ })
    } else {
        foreach ($f in $files) {
            try {
                Invoke-WebRequest -MaximumRetryCount 3 -OutFile "$Tmp/$f" "$BaseUrl/$Tag/$f"
            } catch {
                throw "cannot download ${f}: $($_.Exception.Message)"
            }
        }
    }
    foreach ($f in $files) {
        if (-not (Test-Path "$Tmp/$f")) { throw "release $Tag has no $f" }
    }

    # "<sha256>  <file>" or "<sha256> *<file>"
    $sums = @{}
    foreach ($line in Get-Content "$Tmp/SHA256SUMS") {
        if ($line -match '^([0-9a-f]{64}) [ *](.+)$') { $sums[$Matches[2]] = $Matches[1] }
    }
    foreach ($f in $files | Where-Object { $_ -ne 'SHA256SUMS' }) {
        if (-not $sums.ContainsKey($f)) { throw "$f is not in the release's SHA256SUMS" }
        if ((Get-FileHash -Algorithm SHA256 "$Tmp/$f").Hash -ne $sums[$f].ToUpperInvariant()) { throw "checksum mismatch for $f" }
    }

    # The libraries must be the SDL version and options the bindings were made for. Compared without the CRs that a checkout
    # with core.autocrlf may have added.
    function Get-Text([string]$Path) { (Get-Content -Raw $Path) -replace "`r", '' }
    $sources = ((Get-Content $Pin | Where-Object { $_ -match '^SDL_(VERSION|SHA256)=' }) -join "`n") + "`n"
    if ($sources -cne (Get-Text "$Tmp/sources.env")) {
        throw "upstream/release.env's SDL differs from release ${Tag}'s: SDL was updated since. Build the libraries with tools/build_sdl3.ps1"
    }
    if ((Get-Text "$Tmp/sdl3_options.cmake") -cne (Get-Text (Join-Path $Repo 'upstream/sdl3_options.cmake'))) {
        throw "upstream/sdl3_options.cmake differs from release ${Tag}'s: the options changed since. Build the libraries with tools/build_sdl3.ps1"
    }

    foreach ($platform in $Platforms) {
        # The archives hold lib/<platform>/<libraries>. tar is in Windows 10 and later.
        tar -xzf "$Tmp/sdl3-$platform.tar.gz" -C $Repo
        Write-Host "Extracted to lib/${platform}/:"
        Get-ChildItem (Join-Path $Repo "lib/$platform") | Format-Table Name, Length -AutoSize | Out-Host
    }
} finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
