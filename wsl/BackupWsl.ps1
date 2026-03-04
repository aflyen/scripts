# ==========================================
# WSL Monthly Backup Script
# ==========================================
#
# Purpose
# -------
# Creates a monthly backup of all installed WSL distributions
# using the official `wsl --export` command.
#
# Backup location
# ---------------
# Backups are stored in:
# C:\Users\<Username>\Backups\WSL
#
# Naming convention
# -----------------
# Backup files are named using the format:
#
#   WSL-<DistroName>-MM-YYYY.tar
#
# Example:
#
#   WSL-Ubuntu-24.04-03-2026.tar
#
# Retention policy
# ----------------
# Old backups are automatically deleted based on the configured
# retention period (default: 6 months).
#
# This means:
# - A new backup is created each month.
# - Existing backups are kept until they are older than the
#   retention period.
# - Backups are NOT deleted simply because a new backup was created.
#
# Example timeline (6 month retention):
#
#   Oct 2025  -> kept
#   Nov 2025  -> kept
#   Dec 2025  -> kept
#   Jan 2026  -> kept
#   Feb 2026  -> kept
#   Mar 2026  -> kept
#   Sep 2025  -> deleted
#
# Notes
# -----
# - WSL is shut down before export to ensure filesystem consistency.
# - Script can safely be scheduled (e.g. monthly in Task Scheduler).
#
# ==========================================


# Parameters / Configuration
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$BackupFolder = (Join-Path $env:USERPROFILE "Backups\WSL"),

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 120)]
    [int]$RetentionMonths = 6
)

$date = Get-Date -Format "MM-yyyy"

# Create backup folder if it doesn't exist
if (-not (Test-Path $backupFolder)) {
    New-Item -ItemType Directory -Path $backupFolder | Out-Null
    Write-Host "Created backup folder: $backupFolder"
}

# Start logging
$logFile = Join-Path $backupFolder "backup-log.txt"
Start-Transcript -Path $logFile -Append

Write-Host "=========================================="
Write-Host "WSL Backup started: $(Get-Date)"
Write-Host "=========================================="
Write-Host "Backup folder: $BackupFolder"
Write-Host "Retention (months): $RetentionMonths"

Write-Host "Stopping WSL..."
wsl --shutdown

# Get installed WSL distros (fix null-byte encoding issue from wsl.exe output)
$distros = wsl -l -q | ForEach-Object {
    $_ -replace "`0", ""
} | Where-Object { $_.Trim() -ne "" }

$failed = @()

foreach ($distro in $distros) {
    $distro = $distro.Trim()
    $fileName = "WSL-$distro-$date.tar"
    $backupPath = Join-Path $backupFolder $fileName

    if (Test-Path $backupPath) {
        Write-Host "Backup already exists for $distro ($date). Skipping..."
        continue
    }

    Write-Host "Exporting $distro..."
    wsl --export $distro $backupPath

    if (Test-Path $backupPath) {
        Write-Host "Backup created: $backupPath"
    }
    else {
        Write-Warning "Backup FAILED for $distro"
        $failed += $distro
    }
}

# Cleanup old backups
Write-Host "Cleaning up old backups..."
$limit = (Get-Date).AddMonths(-$RetentionMonths)
Get-ChildItem $BackupFolder -Filter "WSL-*.tar" | Where-Object {
    $_.CreationTime -lt $limit
} | Remove-Item -Force

Write-Host "=========================================="
Write-Host "WSL Backup finished: $(Get-Date)"
Write-Host "=========================================="

Stop-Transcript

if ($failed.Count -gt 0) {
    Write-Warning "The following distros failed to back up: $($failed -join ', ')"
    exit 1
}