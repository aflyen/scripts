# WSL Backup

Automated backup utility for Windows Subsystem for Linux (WSL) distributions. Creates monthly backups of all installed WSL distros and manages retention automatically.

## Features

- Backs up all installed WSL distributions using `wsl --export`
- Monthly backup naming convention: `WSL-<DistroName>-MM-YYYY.tar`
- Automatic retention policy to remove backups older than a configured period (default: 6 months)
- Logs all operations including failures and timing
- Safely shuts down WSL before export to ensure filesystem consistency
- Safe for scheduled execution (e.g., Task Scheduler)

## Backup Location

Backups are stored in `C:\Users\<Username>\Backups\WSL` by default, with a transaction log at `backup-log.txt` in the same directory.

## Retention Policy

With default 6-month retention:
- New backup created each month
- Previous backups kept until they exceed the retention period
- Old backups automatically deleted (not on each run, but when their age is exceeded)

Example (6 month retention):
- Oct 2025 → kept
- Nov 2025 → kept
- Dec 2025 → kept
- Jan 2026 → kept
- Feb 2026 → kept
- Mar 2026 → kept
- Sep 2025 → deleted

## Usage

Basic usage (default folder and 6-month retention):

```powershell
.\BackupWsl.ps1
```

Custom backup folder and retention period:

```powershell
.\BackupWsl.ps1 -BackupFolder "D:\WSL-Backups" -RetentionMonths 12
```

## Scheduling

To run automatically each month, add to Windows Task Scheduler:
- **Trigger**: Monthly (first day of month, or desired schedule)
- **Action**: `powershell.exe -NoProfile -File C:\path\to\BackupWsl.ps1`
- **Run with highest privileges**: Recommended

## Requirements

- Windows 10/11 with WSL 2 installed
- `wsl` command available in PATH
- PowerShell 5.0+
