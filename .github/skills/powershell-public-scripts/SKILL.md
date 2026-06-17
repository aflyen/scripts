---
name: powershell-public-scripts
description: Build generic, shareable, well-documented PowerShell scripts for public GitHub repositories. Use when creating or refactoring PowerShell scripts intended for broad reuse by others.
license: See repository LICENSE
---

# PowerShell Public Scripts Skill

## Purpose

Use this skill when the user wants PowerShell scripts that are safe to publish, easy to understand, and easy for others to run without private environment assumptions.

## When To Use

Use this skill when requests include one or more of the following:

- Create a new PowerShell script for a public repository.
- Improve script quality for sharing and open-source use.
- Add or improve script documentation, examples, and usability.
- Refactor hardcoded or tenant-specific scripts into generic reusable tools.
- Add validation, help text, logging, or safer execution behavior.

## Core Principles

1. Keep scripts generic and reusable.
2. Minimize assumptions about user environment.
3. Make usage discoverable through built-in help and README examples.
4. Prefer safe defaults and explicit confirmation for destructive actions.
5. Use approved PowerShell verbs and consistent naming.

## Script Quality Checklist

Every script created or modified with this skill should include:

1. Standard script header with synopsis, description, author, date, and link.
2. Comment-based help with at least `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, and `.EXAMPLE`.
3. `[CmdletBinding()]` and strongly typed parameters.
4. Input validation (`ValidateSet`, `ValidateNotNullOrEmpty`, path checks, etc.).
5. Clear error handling using `try/catch` with actionable messages.
6. Pipeline support when it improves usability (`ValueFromPipeline`).
7. Output suitable for automation (objects over plain text when possible).
8. No hardcoded tenant IDs, secrets, usernames, absolute private paths, or org-specific endpoints.

## Repository Conventions (from this repo)

1. Follow the header structure from `DefaultScriptHeader.ps1`.
2. Use `#Requires -Version 7.0` for scripts requiring PowerShell 7+ features.
3. Keep each script self-contained in its feature folder with any needed JSON data files.
4. For long-running jobs, use transcript logging, stopwatch timing, progress counters, and timestamped outputs.
5. For scripts that mutate SharePoint or Microsoft 365 content, require explicit user confirmation before changes.

## Public GitHub Readiness Rules

1. Add a short README usage section for each script folder.
2. Include practical examples:
   - Basic invocation
   - Advanced invocation
   - Pipeline usage (if supported)
3. Document required dependencies and installation steps.
4. Explain expected permissions and authentication requirements.
5. Describe output format and where files/logs are written.
6. Add sample data files for test runs when relevant.

## Security and Safety Requirements

1. Never embed secrets, tokens, or credentials in code.
2. Support secure credential input patterns when needed.
3. Use `SupportsShouldProcess` and `-WhatIf` for mutating operations where practical.
4. Prompt for explicit confirmation before high-impact operations.
5. Fail fast on invalid input with clear errors.

## Portability Requirements

1. Avoid Windows-only behavior unless clearly documented.
2. For clipboard support, use cross-platform branches (`Set-Clipboard`, `pbcopy`, `xclip`/`xsel`).
3. Prefer relative paths and configurable parameters over fixed directories.
4. Detect and report missing external tools/modules with install guidance.

## Suggested Script Skeleton

```powershell
#Requires -Version 7.0

<#
.SYNOPSIS
	Brief summary of what the script does.
.DESCRIPTION
	Longer description of behavior, inputs, outputs, and constraints.
.PARAMETER InputPath
	Path to input data.
.EXAMPLE
	.\Invoke-MyTask.ps1 -InputPath .\sample-data.json
.NOTES
	Author    : Are Flyen
	Date      : DD.MM.YYYY
.LINK
	https://www.areflyen.no
#>

[CmdletBinding(SupportsShouldProcess)]
param(
	[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
	[ValidateNotNullOrEmpty()]
	[string]$InputPath,

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]$OutputPath = ".\reports"
)

begin {
	Set-StrictMode -Version Latest
	$ErrorActionPreference = 'Stop'
}

process {
	try {
		if (-not (Test-Path -Path $InputPath)) {
			throw "Input path not found: $InputPath"
		}

		if ($PSCmdlet.ShouldProcess($InputPath, 'Process input data')) {
			# Main logic goes here.
			[pscustomobject]@{
				InputPath  = $InputPath
				OutputPath = $OutputPath
				Status     = 'Success'
			}
		}
	}
	catch {
		Write-Error "Processing failed for '$InputPath'. $($_.Exception.Message)"
	}
}
```

## Anti-Patterns To Avoid

1. Hidden side effects without confirmation.
2. Scripts that only work in one tenant or one machine setup.
3. Sparse or missing help text.
4. Non-actionable error messages.
5. Returning only formatted strings when objects are expected.

## Definition of Done

A script is done when:

1. It is generic and works for external users with documented prerequisites.
2. It includes complete help and examples.
3. It follows repository structure and PowerShell naming conventions.
4. It includes safe behavior for destructive actions.
5. It can be run by someone new to the repo with minimal friction.
