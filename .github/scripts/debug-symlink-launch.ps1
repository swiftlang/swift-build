##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift open source project
##
## Copyright (c) 2026 Apple Inc. and the Swift project authors
## Licensed under Apache License v2.0 with Runtime Library Exception
##
## See http://swift.org/LICENSE.txt for license information
## See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
##
##===----------------------------------------------------------------------===##

# DEBUG ONLY: find out why launching a symlink to the toolchain's swiftc.exe
# fails on Windows while a symlink to clang.exe works
# (ToolsetTaskConstructionTests.toolsetCustomization).

Set-PSDebug -Trace 0

$Tools = @("swiftc", "swift-driver", "swift-frontend", "clang", "clang++")

function Show-FileInfo([string]$Path) {
    Write-Host "--- $Path"
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "    (does not exist)"
        return
    }
    $Item = Get-Item -LiteralPath $Path -Force
    Write-Host "    Length:     $($Item.Length)"
    Write-Host "    Attributes: $($Item.Attributes)"
    Write-Host "    LinkType:   $($Item.LinkType)"
    Write-Host "    Target:     $($Item.Target)"
    Write-Host "    fsutil reparsepoint query:"
    & fsutil reparsepoint query $Path 2>&1 | ForEach-Object { Write-Host "        $_" }
    Write-Host "    fsutil hardlink list:"
    & fsutil hardlink list $Path 2>&1 | ForEach-Object { Write-Host "        $_" }
    $Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
    Write-Host "    SHA256:     $Hash"
}

# Launch with CreateProcess (UseShellExecute = false), like Foundation.Process does, and report the Win32 error.
function Test-Launch([string]$Path) {
    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $Path
    $StartInfo.Arguments = "--version"
    $StartInfo.UseShellExecute = $false
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    try {
        $Process = [System.Diagnostics.Process]::Start($StartInfo)
        $Stdout = $Process.StandardOutput.ReadToEnd()
        $Stderr = $Process.StandardError.ReadToEnd()
        $Process.WaitForExit()
        $FirstLine = (($Stdout + $Stderr) -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        Write-Host "    launch OK: exit $($Process.ExitCode); $FirstLine"
    } catch {
        $Inner = $_.Exception
        while ($Inner.InnerException) { $Inner = $Inner.InnerException }
        if ($Inner -is [System.ComponentModel.Win32Exception]) {
            Write-Host "    launch FAILED: Win32 error $($Inner.NativeErrorCode): $($Inner.Message)"
        } else {
            Write-Host "    launch FAILED: $($Inner.GetType().FullName): $($Inner.Message)"
        }
    }
}

Write-Host "===== Toolchain tools"
$Originals = @{}
foreach ($Tool in $Tools) {
    $Command = Get-Command "$Tool.exe" -ErrorAction SilentlyContinue
    if (-not $Command) {
        Write-Host "--- $Tool.exe: not found on PATH"
        continue
    }
    $Originals[$Tool] = $Command.Path
    Show-FileInfo $Command.Path
    Test-Launch $Command.Path
}

$LinkDir = Join-Path $env:TEMP "symlink-launch-test"
Remove-Item -LiteralPath $LinkDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $LinkDir | Out-Null

Write-Host ""
Write-Host "===== Symlinks to the toolchain tools"
foreach ($Tool in $Tools) {
    if (-not $Originals.ContainsKey($Tool)) { continue }
    $Target = $Originals[$Tool]
    # Plain absolute target, and the \\?\-prefixed form Foundation's createSymbolicLink writes.
    foreach ($Variant in @(@{ Name = "plain"; Target = $Target }, @{ Name = "nt-prefixed"; Target = "\\?\$Target" })) {
        $Link = Join-Path $LinkDir "$($Variant.Name)\$Tool.exe"
        New-Item -ItemType Directory -Path (Split-Path $Link) -Force | Out-Null
        $Output = & cmd /c mklink "$Link" "$($Variant.Target)" 2>&1
        Write-Host ""
        Write-Host "=== $Tool ($($Variant.Name) target): mklink: $Output"
        Show-FileInfo $Link
        Test-Launch $Link
    }
}

Write-Host ""
Write-Host "===== Foundation createSymbolicLink + Foundation.Process + CreateProcessW"
$Exe = Join-Path $env:TEMP "debug-symlink-launch.exe"
& swiftc -sdk $env:SDKROOT (Join-Path $PSScriptRoot "debug-symlink-launch.swift") -o $Exe
if ($LastExitCode -ne 0) {
    Write-Host "failed to compile debug-symlink-launch.swift"
    exit 1
}
& $Exe (Join-Path $env:TEMP "foundation-symlink-launch-test") @($Tools | Where-Object { $Originals.ContainsKey($_) } | ForEach-Object { $Originals[$_] })
foreach ($Tool in $Tools) {
    if ($Originals.ContainsKey($Tool)) {
        Show-FileInfo (Join-Path $env:TEMP "foundation-symlink-launch-test\$Tool.exe")
    }
}
