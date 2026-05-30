<#
.SYNOPSIS
    Harness CLI wrapper for Windows (PowerShell).

.DESCRIPTION
    Thin wrapper that delegates to the prebuilt Rust harness-cli binary.
    Equivalent of scripts/harness (bash) for Windows environments.

.EXAMPLE
    .\scripts\harness.ps1 init
    .\scripts\harness.ps1 query matrix
    .\scripts\harness.ps1 intake --type "new spec" --summary "Add auth" --lane normal
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$env:HARNESS_REPO_ROOT = $RepoRoot

if (-not $env:HARNESS_DB) {
    $env:HARNESS_DB = Join-Path $RepoRoot "harness.db"
}

# ── locate Rust CLI binary ─────────────────────────────────────────
$RustCli = $null

if ($env:HARNESS_RUST_CLI -and (Test-Path $env:HARNESS_RUST_CLI)) {
    $RustCli = $env:HARNESS_RUST_CLI
}
else {
    $installedCli = Join-Path $RepoRoot "scripts/bin/harness-cli.exe"
    $devCli = Join-Path $RepoRoot "target/debug/harness-cli.exe"

    # Also check non-.exe names (Git Bash / WSL interop)
    $installedCliUnix = Join-Path $RepoRoot "scripts/bin/harness-cli"

    if (Test-Path $installedCli) {
        $RustCli = $installedCli
    }
    elseif (Test-Path $installedCliUnix) {
        $RustCli = $installedCliUnix
    }
    elseif (Test-Path $devCli) {
        $RustCli = $devCli
    }
}

if (-not $RustCli) {
    Write-Host @"
error: Harness CLI binary not found.

Looked for:
  - scripts\bin\harness-cli.exe   (prebuilt, installed by install-harness.ps1)
  - target\debug\harness-cli.exe  (dev build via 'cargo build')

To install the prebuilt binary, run:
  .\scripts\install-harness.ps1 -Merge -Yes

Or build from source:
  cargo build --package harness-cli
"@ -ForegroundColor Red
    exit 1
}

# ── delegate to Rust CLI ───────────────────────────────────────────
if ($Arguments -and $Arguments.Count -gt 0) {
    & $RustCli @Arguments
}
else {
    & $RustCli --help
}

exit ($LASTEXITCODE -as [int])
