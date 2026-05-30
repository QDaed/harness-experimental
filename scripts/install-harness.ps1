<#
.SYNOPSIS
    Install Harness v0 files and folders into a target project directory (Windows).

.DESCRIPTION
    PowerShell port of install-harness.sh. Downloads and installs the Harness
    framework files, templates, and the prebuilt Rust CLI into a target project.

.PARAMETER Directory
    Target directory. Defaults to the current directory.

.PARAMETER Yes
    Accept defaults and skip prompts.

.PARAMETER Merge
    On protected-path conflict, keep existing files and install only missing
    Harness files.

.PARAMETER RefreshAgentShim
    Refresh an existing AGENTS.md into the small Harness shim after backing
    it up.

.PARAMETER Override
    On protected-path conflict, back up and replace AGENTS.md, docs/, and
    scripts/.

.PARAMETER Force
    Overwrite existing files after backing them up.

.PARAMETER DryRun
    Show what would change without writing files.

.EXAMPLE
    .\install-harness.ps1 -Yes
    .\install-harness.ps1 -Directory C:\Projects\myapp -Yes
    .\install-harness.ps1 -Merge -Yes
    .\install-harness.ps1 -Override -Yes
#>
[CmdletBinding()]
param(
    [Alias("d")]
    [string]$Directory = "",

    [Alias("y")]
    [switch]$Yes,

    [switch]$Merge,

    [switch]$RefreshAgentShim,

    [switch]$Override,

    [switch]$Force,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── globals ────────────────────────────────────────────────────────
$script:Created = 0
$script:Updated = 0
$script:Skipped = 0
$script:ConflictAction = "install"

# ── helpers ────────────────────────────────────────────────────────
function Log($msg) { Write-Host $msg }

function Fail($msg) {
    Write-Error "Error: $msg"
    exit 1
}

function WarnStop($msg) {
    Write-Warning $msg
    exit 1
}

function Expand-TargetPath($inputPath) {
    if ([string]::IsNullOrWhiteSpace($inputPath)) {
        return (Get-Location).Path
    }
    if ($inputPath.StartsWith("~")) {
        $inputPath = Join-Path $HOME $inputPath.Substring(1).TrimStart("/\")
    }
    return [System.IO.Path]::GetFullPath($inputPath)
}

# ── source helpers ─────────────────────────────────────────────────
function Write-SourceFile {
    param([string]$Relative, [string]$TargetPath)

    if ($script:SourceMode -eq "local") {
        $sourcePath = Join-Path $script:SourceRoot $Relative
        if (-not (Test-Path $sourcePath)) { Fail "Source file missing: $sourcePath" }
        Copy-Item $sourcePath $TargetPath -Force
        return
    }

    $url = "$($script:SourceBaseUrl)/$Relative"
    try {
        Invoke-WebRequest -Uri $url -OutFile $TargetPath -UseBasicParsing -ErrorAction Stop | Out-Null
    }
    catch {
        Fail "Could not download $url"
    }
}

function Merge-Gitignore {
    param([string]$TargetPath)
    $marker = "# Harness durable layer"
    $rules = @("harness.db", "harness.db-wal", "harness.db-shm", "scripts/bin/harness-cli", "scripts/bin/harness-cli.exe")

    $content = Get-Content $TargetPath -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { $content = "" }

    $allPresent = $true
    foreach ($rule in $rules) {
        if ($content -notmatch [regex]::Escape($rule)) {
            $allPresent = $false
            break
        }
    }

    if ($allPresent) {
        Log "skip     .gitignore (harness rules already present)"
        $script:Skipped++
        return
    }

    if ($DryRun) {
        Log "update   .gitignore (append harness rules)"
    }
    else {
        $appendText = "`n$marker`n$($rules -join "`n")`n"
        Add-Content -Path $TargetPath -Value $appendText -NoNewline
        Log "updated  .gitignore (appended harness rules)"
    }
    $script:Updated++
}

function Copy-HarnessFile {
    param([string]$Relative)

    $targetPath = Join-Path $script:TargetDir $Relative

    # .gitignore merge logic
    if ($Relative -eq ".gitignore" -and (Test-Path $targetPath) -and -not $Force) {
        Merge-Gitignore $targetPath
        return
    }

    if (Test-Path $targetPath) {
        if ($script:SourceMode -eq "local") {
            $sourcePath = Join-Path $script:SourceRoot $Relative
            if ((Test-Path $sourcePath) -and
                (Resolve-Path $sourcePath).Path -eq (Resolve-Path $targetPath).Path) {
                Log "skip     $Relative (source file)"
                $script:Skipped++
                return
            }
        }

        if ($script:ConflictAction -eq "merge") {
            Log "skip     $Relative (merge keeps existing file)"
            $script:Skipped++
        }
        elseif ($Force) {
            if ($DryRun) {
                Log "overwrite $Relative (backup first)"
            }
            else {
                $backupPath = Join-Path $script:BackupDir $Relative
                $backupParent = Split-Path $backupPath -Parent
                if (-not (Test-Path $backupParent)) { New-Item -ItemType Directory -Path $backupParent -Force | Out-Null }
                Copy-Item $targetPath $backupPath -Force
                Write-SourceFile $Relative $targetPath
                Log "updated $Relative (backup: $($backupPath.Replace($script:TargetDir, '').TrimStart('\')))"
            }
            $script:Updated++
        }
        else {
            Log "skip     $Relative (already exists)"
            $script:Skipped++
        }
        return
    }

    if ($DryRun) {
        Log "create   $Relative"
    }
    else {
        $parentDir = Split-Path $targetPath -Parent
        if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
        Write-SourceFile $Relative $targetPath
        Log "created  $Relative"
    }
    $script:Created++
}

# ── agent shim ─────────────────────────────────────────────────────
function Get-AgentShimBlock {
    return @"
<!-- HARNESS:BEGIN -->
## Harness

This repo uses Harness. Before work, read:

- ``README.md``
- ``docs/HARNESS.md``
- ``docs/FEATURE_INTAKE.md``
- ``docs/ARCHITECTURE.md``
- ``docs/CONTEXT_RULES.md``
- ``scripts/harness query matrix``

Use the Rust Harness CLI as the main operational tool. Run it through the
stable repo-local entrypoint ``scripts/harness`` (or ``scripts/harness.ps1``
on Windows), which uses the prebuilt Rust binary at
``scripts/bin/harness-cli`` in installed projects.
<!-- HARNESS:END -->
"@
}

function Test-OldHarnessAgentFile {
    param([string]$TargetPath)
    $content = Get-Content $TargetPath -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { return $false }
    return ($content -match "# Agent Operating Guide") -and
           ($content -match "## Source Of Truth") -and
           ($content -match "## Task Loop") -and
           ($content -match "## Done Definition")
}

function Backup-AgentFile {
    $agentPath = Join-Path $script:TargetDir "AGENTS.md"
    if (-not (Test-Path $agentPath)) { return }
    if (-not (Test-Path $script:BackupDir)) {
        New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
    }
    $backupPath = Join-Path $script:BackupDir "AGENTS.md"
    if (Test-Path $backupPath) { return }
    Copy-Item $agentPath $backupPath -Force
}

function Update-AgentHarnessBlock {
    $agentPath = Join-Path $script:TargetDir "AGENTS.md"
    $content = Get-Content $agentPath -Raw
    $block = Get-AgentShimBlock

    if ($content -match "<!-- HARNESS:BEGIN -->" -and $content -match "<!-- HARNESS:END -->") {
        $content = $content -replace "(?s)<!-- HARNESS:BEGIN -->.*?<!-- HARNESS:END -->", $block
    }
    else {
        $content = "$content`n$block"
    }
    Set-Content -Path $agentPath -Value $content -NoNewline
}

function Invoke-RefreshAgentShim {
    if (-not $RefreshAgentShim) { return }

    $agentPath = Join-Path $script:TargetDir "AGENTS.md"
    if (-not (Test-Path $agentPath)) { return }

    if ($script:SourceMode -eq "local") {
        $sourcePath = Join-Path $script:SourceRoot "AGENTS.md"
        if ((Resolve-Path $sourcePath).Path -eq (Resolve-Path $agentPath).Path) {
            Log "skip     AGENTS.md (source file)"
            return
        }
    }

    if ($DryRun) {
        if (Test-OldHarnessAgentFile $agentPath) {
            Log "refresh  AGENTS.md (old Harness guide -> shim, backup first)"
        }
        else {
            Log "refresh  AGENTS.md (append or replace marked Harness block, backup first)"
        }
        $script:Updated++
        return
    }

    Backup-AgentFile
    if (Test-OldHarnessAgentFile $agentPath) {
        Write-SourceFile "AGENTS.md" $agentPath
        Log "updated  AGENTS.md (old Harness guide -> shim)"
    }
    else {
        Update-AgentHarnessBlock
        Log "updated  AGENTS.md (refreshed Harness block)"
    }
    $script:Updated++
}

# ── CLI binary download ───────────────────────────────────────────
function Get-CliPlatform {
    if ($env:HARNESS_CLI_PLATFORM) { return $env:HARNESS_CLI_PLATFORM }

    if ($IsLinux) {
        $arch = uname -m
        switch ($arch) {
            "x86_64"  { return "linux-x64" }
            "aarch64" { return "linux-arm64" }
            "arm64"   { return "linux-arm64" }
            default   { Fail "Unsupported Linux architecture: $arch" }
        }
    }
    elseif ($IsMacOS) {
        $arch = uname -m
        switch ($arch) {
            "arm64"   { return "macos-arm64" }
            "x86_64"  { return "macos-x64" }
            default   { Fail "Unsupported macOS architecture: $arch" }
        }
    }
    else {
        # Windows
        $arch = $env:PROCESSOR_ARCHITECTURE
        # On 64-bit Windows running a 32-bit PowerShell process, PROCESSOR_ARCHITECTURE
        # reports "x86"; check PROCESSOR_ARCHITEW6432 to detect the real machine arch.
        if ($arch -eq "x86" -and $env:PROCESSOR_ARCHITEW6432) {
            $arch = $env:PROCESSOR_ARCHITEW6432
        }
        switch ($arch) {
            "AMD64" { return "windows-x64" }
            "x86"   { return "windows-x64" }
            "ARM64" { return "windows-arm64" }
            default { Fail "Unsupported Windows architecture: $arch" }
        }
    }
}

function Get-Sha256Hash($filePath) {
    $hash = Get-FileHash -Path $filePath -Algorithm SHA256
    return $hash.Hash.ToLower()
}

function Install-HarnessCliBinary {
    $platform = Get-CliPlatform

    if ($platform -like "windows-*") {
        $binaryName = "harness-cli-${platform}.exe"
    }
    else {
        $binaryName = "harness-cli-$platform"
    }

    $binaryUrl = "$($script:CliBaseUrl)/$binaryName"
    $checksumUrl = "$binaryUrl.sha256"

    if ($platform -like "windows-*") {
        $targetPath = Join-Path $script:TargetDir "scripts/bin/harness-cli.exe"
    }
    else {
        $targetPath = Join-Path $script:TargetDir "scripts/bin/harness-cli"
    }

    if ((Test-Path $targetPath) -and $script:ConflictAction -eq "merge" -and -not $Force) {
        Log "skip     scripts/bin/harness-cli (merge keeps existing file)"
        $script:Skipped++
        return
    }

    if ($DryRun) {
        $dryRunTarget = if ($platform -like "windows-*") { "scripts/bin/harness-cli.exe" } else { "scripts/bin/harness-cli" }
        Log "download $binaryName -> $dryRunTarget"
        Log "verify   ${binaryName}.sha256"
        $script:Created++
        return
    }

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "harness-cli-$(Get-Random)"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $binaryTmp = Join-Path $tmpDir $binaryName
    $checksumTmp = Join-Path $tmpDir "$binaryName.sha256"

    try {
        Invoke-WebRequest -Uri $binaryUrl -OutFile $binaryTmp -UseBasicParsing -ErrorAction Stop | Out-Null
    }
    catch {
        Fail "Could not download $binaryUrl"
    }

    try {
        Invoke-WebRequest -Uri $checksumUrl -OutFile $checksumTmp -UseBasicParsing -ErrorAction Stop | Out-Null
    }
    catch {
        Fail "Could not download $checksumUrl"
    }

    $expected = (Get-Content $checksumTmp -Raw).Trim().Split()[0]
    if ([string]::IsNullOrWhiteSpace($expected)) { Fail "Checksum file is empty: $checksumUrl" }
    $actual = Get-Sha256Hash $binaryTmp
    if ($actual -ne $expected) {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        Fail "Checksum mismatch for ${binaryName}: expected $expected, got $actual"
    }

    $targetDir = Split-Path $targetPath -Parent
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }

    if (Test-Path $targetPath) {
        if ($Force) {
            $backupBin = Join-Path $script:BackupDir "scripts/bin"
            if (-not (Test-Path $backupBin)) { New-Item -ItemType Directory -Path $backupBin -Force | Out-Null }
            Copy-Item $targetPath (Join-Path $backupBin (Split-Path $targetPath -Leaf)) -Force
        }
        $script:Updated++
        Log "updated  scripts/bin/harness-cli"
    }
    else {
        $script:Created++
        Log "created  scripts/bin/harness-cli"
    }

    Copy-Item $binaryTmp $targetPath -Force
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Log "verified scripts/bin/harness-cli ($platform)"
}

# ── protected paths ────────────────────────────────────────────────
function Test-ProtectedTargetPaths {
    $conflicts = @()
    if (Test-Path (Join-Path $script:TargetDir "AGENTS.md")) { $conflicts += "AGENTS.md" }
    if (Test-Path (Join-Path $script:TargetDir "docs")) { $conflicts += "docs/" }
    if (Test-Path (Join-Path $script:TargetDir "scripts")) { $conflicts += "scripts/" }

    if ($conflicts.Count -eq 0) { return }

    $joined = $conflicts -join ", "

    if ($Merge) {
        $script:ConflictAction = "merge"
        Log "Continuing with merge. Existing files will be skipped."
        return
    }

    if ($Override) {
        $script:ConflictAction = "override"
        Invoke-OverrideProtectedPaths
        return
    }

    if ($Yes) {
        WarnStop "target already contains protected Harness paths: $joined. Use -Merge or -Override."
    }

    Write-Host "Warning: target already contains protected Harness paths: $joined"
    Write-Host "Choose how to continue:"
    Write-Host "  1. Merge    Copy missing Harness files and skip existing files"
    Write-Host "  2. Override Back up and replace AGENTS.md, docs/, and scripts/"
    Write-Host "  3. Stop     Exit without writing files (recommended)"
    $choice = Read-Host "Choice [1/2/3, default 3]"

    switch ($choice) {
        { $_ -in "1", "m", "merge" } {
            $script:ConflictAction = "merge"
            Log "Continuing with merge. Existing files will be skipped."
        }
        { $_ -in "2", "o", "override" } {
            $script:ConflictAction = "override"
            Invoke-OverrideProtectedPaths
        }
        default {
            WarnStop "installation stopped by user."
        }
    }
}

function Invoke-OverrideProtectedPaths {
    foreach ($protected in @("AGENTS.md", "docs", "scripts")) {
        $protectedPath = Join-Path $script:TargetDir $protected
        if (-not (Test-Path $protectedPath)) { continue }

        if ($DryRun) {
            Log "override $protected (backup first)"
            continue
        }

        if (-not (Test-Path $script:BackupDir)) {
            New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
        }
        $backupDest = Join-Path $script:BackupDir $protected
        Move-Item $protectedPath $backupDest -Force
        Log "removed  $protected (backup: $($script:BackupDir.Replace($script:TargetDir, '').TrimStart('\'))/$protected)"
    }
}

# ── main ───────────────────────────────────────────────────────────

# Resolve target directory
$targetInput = if ($Directory) { $Directory } else { (Get-Location).Path }
$script:TargetDir = Expand-TargetPath $targetInput
$script:BackupDir = Join-Path $script:TargetDir ".harness-backup/$(Get-Date -Format 'yyyyMMddHHmmss')"

# Determine source mode
$scriptDir = $PSScriptRoot
$script:SourceRoot = ""
$script:SourceMode = "remote"
$script:SourceBaseUrl = if ($env:HARNESS_SOURCE_BASE_URL) {
    $env:HARNESS_SOURCE_BASE_URL.TrimEnd("/")
}
else {
    "https://raw.githubusercontent.com/QDaed/harness-experimental/main"
}

$script:CliBaseUrl = if ($env:HARNESS_CLI_BASE_URL) {
    $env:HARNESS_CLI_BASE_URL.TrimEnd("/")
}
else {
    "https://github.com/QDaed/harness-experimental/releases/latest/download"
}

if ($scriptDir -and (Test-Path (Join-Path (Split-Path $scriptDir -Parent) "AGENTS.md")) -and
    (Test-Path (Join-Path (Split-Path $scriptDir -Parent) "docs/HARNESS.md"))) {
    $script:SourceRoot = (Resolve-Path (Join-Path $scriptDir "..")).Path
    $script:SourceMode = "local"
}

if (-not $Yes) {
    $reply = Read-Host "Install Harness v0 into [$targetInput]"
    if ($reply) { $script:TargetDir = Expand-TargetPath $reply }
}

if ($DryRun) {
    Log "Dry run: no files will be written."
}
elseif (-not (Test-Path $script:TargetDir)) {
    New-Item -ItemType Directory -Path $script:TargetDir -Force | Out-Null
}

if (-not (Test-Path $script:TargetDir)) {
    if (-not $DryRun) { Fail "Target directory could not be created: $($script:TargetDir)" }
    Log "Target directory would be created: $($script:TargetDir)"
}

if ($script:SourceMode -eq "local") {
    Log "Harness source: $($script:SourceRoot)"
}
else {
    Log "Harness source: $($script:SourceBaseUrl)"
}
Log "Harness CLI source: $($script:CliBaseUrl)"
Log "Target project: $($script:TargetDir)"

# Check protected paths
Test-ProtectedTargetPaths

# Install files
$harnessFiles = @(
    "AGENTS.md"
    "README.md"
    "docs/ARCHITECTURE.md"
    "docs/CONTEXT_RULES.md"
    "docs/FEATURE_INTAKE.md"
    "docs/GLOSSARY.md"
    "docs/HARNESS.md"
    "docs/HARNESS_BACKLOG.md"
    "docs/HARNESS_COMPONENTS.md"
    "docs/HARNESS_MATURITY.md"
    "docs/README.md"
    "docs/TEST_MATRIX.md"
    "docs/TRACE_SPEC.md"
    "docs/decisions/0001-harness-first-development.md"
    "docs/decisions/0002-post-spec-product-lifecycle.md"
    "docs/decisions/0003-generic-spec-intake-harness.md"
    "docs/decisions/0004-sqlite-durable-layer.md"
    "docs/decisions/0005-prebuilt-rust-harness-cli.md"
    "docs/decisions/README.md"
    "docs/product/README.md"
    "docs/stories/README.md"
    "docs/stories/backlog.md"
    "docs/templates/decision.md"
    "docs/templates/spec-intake.md"
    "docs/templates/story.md"
    "docs/templates/validation-report.md"
    "docs/templates/high-risk-story/design.md"
    "docs/templates/high-risk-story/execplan.md"
    "docs/templates/high-risk-story/overview.md"
    "docs/templates/high-risk-story/validation.md"
    "scripts/README.md"
    "scripts/harness"
    "scripts/harness.ps1"
    "scripts/schema/001-init.sql"
    ".gitignore"
)

foreach ($file in $harnessFiles) {
    Copy-HarnessFile $file
}

Invoke-RefreshAgentShim
Install-HarnessCliBinary

Log ""
Log "Done. Created: $($script:Created), updated: $($script:Updated), skipped: $($script:Skipped)."

if ($script:Skipped -gt 0 -and -not $Force) {
    Log "Existing files were left untouched. Re-run with -Force to overwrite with backups."
}

if ($Force -and $script:Updated -gt 0 -and -not $DryRun) {
    Log "Backups were written to: $($script:BackupDir)"
}
