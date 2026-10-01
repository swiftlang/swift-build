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

# DEBUG ONLY: locate tests that stall on Windows.
#
# `swift test` buffers each test runner's output until the runner exits, so a
# stalled runner prints nothing. Instead, build the tests and run each
# swift-testing runner directly so its output streams live, with a per-runner
# timeout. On timeout, dump the runner's child processes and terminate it, then
# continue with the next runner.

param (
    [int]$TimeoutMinutes = 20,
    # Runners to run first (by bundle name), the rest follow in alphabetical order.
    [string[]]$First = @("SWBTaskConstructionTests")
)

Set-PSDebug -Trace 0

& swift build --build-tests
if ($LastExitCode -ne 0) { exit $LastExitCode }

$BinPath = (& swift build --show-bin-path).Trim()
Write-Host "Bin path: $BinPath"

# `swift test` puts the swift-testing and XCTest DLLs from the platform on PATH
# before launching a runner; mirror that, otherwise the runners fail to load
# with STATUS_DLL_NOT_FOUND (0xC0000135).
$PlatformLibrary = Join-Path (Split-Path (Split-Path $env:SDKROOT.TrimEnd('\'))) "Library"
$ArchBinDir = switch ($env:PROCESSOR_ARCHITECTURE) {
    "ARM64" { "bin64a" }
    "x86" { "bin32" }
    default { "bin64" }
}
$TestLibraryDirs = Get-ChildItem -Path $PlatformLibrary -Recurse -Include "Testing.dll", "XCTest.dll" |
    ForEach-Object { $_.DirectoryName } | Sort-Object -Unique |
    Where-Object { (Split-Path $_ -Leaf) -eq $ArchBinDir }
Write-Host "Test library dirs ($ArchBinDir): $($TestLibraryDirs -join '; ')"
if (-not $TestLibraryDirs) {
    Get-ChildItem -Path $PlatformLibrary -Recurse -Include "Testing.dll", "XCTest.dll" | ForEach-Object { Write-Host "  found: $($_.FullName)" }
    exit 1
}
$env:Path = (@($BinPath) + $TestLibraryDirs + @($env:Path)) -join ';'

$Runners = Get-ChildItem -Path $BinPath -Filter "*-test-runner.exe" | Sort-Object Name
$Ordered = @()
foreach ($Name in $First) {
    $Ordered += $Runners | Where-Object { $_.Name -eq "$Name-test-runner.exe" }
}
$Ordered += $Runners | Where-Object { $Ordered.Name -notcontains $_.Name }

function Show-ProcessTree([int]$ParentId, [string]$Indent) {
    Get-CimInstance Win32_Process -Filter "ParentProcessId = $ParentId" | ForEach-Object {
        Write-Host "$Indent[$($_.ProcessId)] $($_.CommandLine)"
        Show-ProcessTree $_.ProcessId "$Indent  "
    }
}

$Results = @()
foreach ($Runner in $Ordered) {
    Write-Host ""
    Write-Host "::group::$($Runner.Name)"
    Write-Host "===== START $($Runner.Name) at $(Get-Date -Format o)"
    $Start = Get-Date
    $Process = Start-Process -FilePath $Runner.FullName `
        -ArgumentList "--very-verbose", "--no-parallel", "--testing-library", "swift-testing" `
        -WorkingDirectory (Get-Location) -NoNewWindow -PassThru
    # Touch Handle so ExitCode is available after the process exits.
    $null = $Process.Handle
    if ($Process.WaitForExit($TimeoutMinutes * 60 * 1000)) {
        $Status = "exit $($Process.ExitCode)"
    } else {
        $Status = "TIMED OUT after $TimeoutMinutes min"
        Write-Host "===== $($Runner.Name) $Status; child processes:"
        Show-ProcessTree $Process.Id "  "
        & taskkill /T /F /PID $Process.Id
    }
    $Elapsed = [int]((Get-Date) - $Start).TotalSeconds
    Write-Host "===== END $($Runner.Name): $Status (${Elapsed}s)"
    Write-Host "::endgroup::"
    $Results += "$($Runner.Name): $Status (${Elapsed}s)"
    if ($Status -eq "exit -1073741515") {
        Write-Host "===== $($Runner.Name) could not load a DLL (0xC0000135); PATH=$env:Path"
        exit 1
    }
}

Write-Host ""
Write-Host "===== SUMMARY"
$Results | ForEach-Object { Write-Host $_ }
if ($Results -notmatch ": exit 0 ") { exit 1 }
