#Requires -Version 7.4
<#
Builds the size-minimized SDL3 into lib/windows-<arch>/: SDL3.lib (static), and SDL3.dll with its import library SDL3.dll.lib
(shared). Windows only: Linux and macOS use tools/build_sdl3.sh, which this follows.

Usage: tools/build_sdl3.ps1 [static|shared|all]   (default: all)

The sources are SDL's release tarball, pinned in upstream/release.env: downloaded into build/ and checked against its SHA256,
then patched with upstream/patches/*.patch if there are any. The options are upstream/sdl3_options.cmake. After configuring,
the build's SDL_build_config.h is checked against upstream/sdl3_expected_windows.txt. CMake finds Visual Studio itself: the
newest installed by default, no developer prompt needed.
Environment:
  CMAKE_GENERATOR     e.g. "Visual Studio 18 2026" to require that version
  SDL3_ALLOW_MISSING  features of the expected list that may be missing, space separated
#>
param(
    [ValidateSet('static', 'shared', 'all')]
    [string]$Linkage = 'all'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$Repo = Split-Path -Parent $PSScriptRoot
if (-not $IsWindows) { throw 'tools/build_sdl3.ps1 builds on Windows: on Linux and macOS, run tools/build_sdl3.sh' }
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) { throw 'cmake is required (https://cmake.org, or Visual Studio''s "C++ CMake tools")' }

$arch, $cmakeArch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64' { 'x86_64', 'x64' }
    'Arm64' { 'arm64', 'ARM64' }
    default { throw "unsupported architecture $_" }
}
$platform = "windows-$arch"
$libDir = Join-Path $Repo "lib/$platform"

$pin = Get-Content (Join-Path $Repo 'upstream/release.env')
$version = ($pin | Select-String '^SDL_VERSION=(.+)$').Matches.Groups[1].Value
$sha256 = ($pin | Select-String '^SDL_SHA256=(.+)$').Matches.Groups[1].Value
if (-not $version -or -not $sha256) { throw 'upstream/release.env needs SDL_VERSION and SDL_SHA256' }

# SOURCES
$build = Join-Path $Repo 'build'
New-Item -ItemType Directory -Force $build | Out-Null
$tarball = Join-Path $build "SDL3-$version.tar.gz"
$src = Join-Path $build "SDL3-$version"
if (-not (Test-Path $tarball)) {
    Write-Host "==> downloading SDL $version"
    Invoke-WebRequest -MaximumRetryCount 3 -OutFile "$tarball.part" "https://github.com/libsdl-org/SDL/releases/download/release-$version/SDL3-$version.tar.gz"
    Move-Item -Force "$tarball.part" $tarball
}
if ((Get-FileHash -Algorithm SHA256 $tarball).Hash -ne $sha256.ToUpperInvariant()) {
    throw "$tarball doesn't match SDL_SHA256 in upstream/release.env; delete it to download again"
}

# The patches are part of what the extracted tree is made from, so a change to them extracts it again.
$patchDir = Join-Path $Repo 'upstream/patches'
$patches = @(if (Test-Path $patchDir) { Get-ChildItem $patchDir -Filter *.patch | Sort-Object Name })
$stamp = (@($sha256) + ($patches | ForEach-Object { (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant() })) -join ' '
$stampFile = Join-Path $src '.sdl3_odin_stamp'
if (-not (Test-Path $stampFile) -or (Get-Content -Raw $stampFile).Trim() -ne $stamp) {
    Write-Host "==> extracting $tarball"
    Remove-Item -Recurse -Force $src -ErrorAction SilentlyContinue
    tar -xzf $tarball -C $build
    foreach ($patch in $patches) {
        Write-Host "==> applying $($patch.Name)"
        git -C $src apply $patch.FullName
    }
    Set-Content -NoNewline $stampFile $stamp
}

# The bindings are generated from upstream/include, so it must be what we build. Compared without the CRs that a checkout
# with core.autocrlf may have added.
$committed = Join-Path $Repo 'upstream/include/SDL3'
foreach ($header in Get-ChildItem (Join-Path $src 'include/SDL3') -Filter *.h) {
    $mine = Join-Path $committed $header.Name
    if (-not (Test-Path $mine) -or ((Get-Content -Raw $mine) -replace "`r", '') -cne ((Get-Content -Raw $header.FullName) -replace "`r", '')) {
        throw "upstream/include/SDL3/$($header.Name) differs from SDL $version's"
    }
}

# Invoke-Logged runs a command with its output in a log file, and shows the end of the log when it fails.
function Invoke-Logged([string]$Log, [scriptblock]$Command) {
    try {
        & $Command *> $Log
    } catch {
        Get-Content -Tail 40 $Log | Out-Host
        throw "failed, see $Log"
    }
}

# CHECK
function Test-Features([string]$Config) {
    $defined = @{}
    foreach ($line in Get-Content $Config) {
        if ($line -match '^#define (\w+)') { $defined[$Matches[1]] = $true }
    }
    $allowed = @(($env:SDL3_ALLOW_MISSING ?? '') -split '\s+' | Where-Object { $_ })
    $failed = $false
    foreach ($line in Get-Content (Join-Path $Repo 'upstream/sdl3_expected_windows.txt')) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $want, $name = $line[0], $line.Substring(1)
        if ($defined[$name] -and $want -eq '-') {
            Write-Host "build_sdl3: $name is on, upstream/sdl3_expected_windows.txt says off"
            $failed = $true
        } elseif (-not $defined[$name] -and $want -eq '+') {
            if ($allowed -contains $name) {
                Write-Host "build_sdl3: warning: $name is missing (allowed by SDL3_ALLOW_MISSING)"
            } else {
                Write-Host "build_sdl3: $name is missing (see $Config)"
                $failed = $true
            }
        }
    }
    return -not $failed
}

# BUILD
New-Item -ItemType Directory -Force $libDir | Out-Null
$linkages = $Linkage -eq 'all' ? @('static', 'shared') : @($Linkage)
foreach ($l in $linkages) {
    $dir = Join-Path $build "$platform-$l"
    Write-Host "==> configuring $l in $dir"
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    $configure = @(
        '-S', $src, '-B', $dir, '-C', (Join-Path $Repo 'upstream/sdl3_options.cmake'),
        "-DSDL_SHARED=$($l -eq 'shared' ? 'ON' : 'OFF')", "-DSDL_STATIC=$($l -eq 'static' ? 'ON' : 'OFF')"
    )
    if (-not $env:CMAKE_GENERATOR -or $env:CMAKE_GENERATOR -like 'Visual Studio*') {
        $configure += '-A', $cmakeArch
    }
    Invoke-Logged "$dir.configure.log" { cmake @configure }

    $config = Get-ChildItem $dir -Recurse -Filter SDL_build_config.h | Where-Object { $_.FullName -like '*minsizerel*' } |
        Select-Object -First 1
    if (-not $config) { $config = Get-ChildItem $dir -Recurse -Filter SDL_build_config.h | Select-Object -First 1 }
    $summary = Get-Content $config.FullName | Select-String '^#define (SDL_(VIDEO_DRIVER|AUDIO_DRIVER|JOYSTICK|HAPTIC|SENSOR|VIDEO_OPENGL|VIDEO_VULKAN)\w*) 1'
    Write-Host (($summary | ForEach-Object { $_.Matches.Groups[1].Value }) -join ' ')
    if (-not (Test-Features $config.FullName)) { throw "the $l build lacks expected features (configure log: $dir.configure.log)" }

    Write-Host "==> building $l"
    Invoke-Logged "$dir.build.log" { cmake --build $dir --config MinSizeRel --parallel }

    $out = Join-Path $dir 'MinSizeRel'
    if (-not (Test-Path $out)) { $out = $dir }
    if ($l -eq 'static') {
        # SDL names its static library SDL3-static.lib; ours is SDL3.lib, and the import library SDL3.dll.lib.
        Copy-Item -Force (Join-Path $out 'SDL3-static.lib') (Join-Path $libDir 'SDL3.lib')
    } else {
        Copy-Item -Force (Join-Path $out 'SDL3.dll') (Join-Path $libDir 'SDL3.dll')
        Copy-Item -Force (Join-Path $out 'SDL3.lib') (Join-Path $libDir 'SDL3.dll.lib')
    }
}
Copy-Item -Force (Join-Path $Repo 'upstream/LICENSE.txt') (Join-Path $libDir 'SDL3_LICENSE.txt')
Get-ChildItem $libDir | Format-Table Name, Length -AutoSize | Out-Host
