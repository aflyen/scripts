# PowerShell Scripts Repository - AI Coding Instructions

## Project Overview
This repository contains a collection of PowerShell utility scripts organized by functionality. Each script follows a consistent structure and is designed to be self-contained within its subdirectory.

## Architecture & Organization

### Directory Structure Pattern
- **Root level**: Contains shared templates (`DefaultScriptHeader.ps1`) and project documentation
- **Feature directories**: Each major functionality lives in its own folder (e.g., `code-name-generator/`, `create-report/`, `spo-unique-permissions/`)
- **Self-contained modules**: Each directory contains all required files (scripts, data files, READMEs)

### Script Header Convention
All PowerShell scripts MUST follow the standardized header format found in `DefaultScriptHeader.ps1`:
```powershell
<# .SYNOPSIS
     Title of the script
.DESCRIPTION
     Description of the script
.NOTES
     Author    : Are Flyen
     Date      : DD.MM.YYYY
.LINK
     https://www.areflyen.no
#>
```

## Key Development Patterns

### PowerShell Version Requirements
- Use `#Requires -Version 7.0` for scripts requiring PowerShell Core features
- Legacy scripts may target older versions for compatibility

### PowerShell Coding Style
Follow Microsoft's PowerShell development guidelines: https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/strongly-encouraged-development-guidelines
- Use approved PowerShell verbs (`Get-`, `Set-`, `New-`, `Remove-`, etc.)
- Follow PascalCase for function names and parameters
- Use `[CmdletBinding()]` and proper parameter attributes
- Include comprehensive comment-based help with `.SYNOPSIS`, `.DESCRIPTION`, `.EXAMPLE`

### Cross-Platform Clipboard Handling
When implementing clipboard functionality, use the pattern from `CodeNameGenerator.ps1`:
```powershell
if ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6 -or $null -eq $IsWindows) {
    Set-Clipboard -Value $Text
}
elseif ($IsLinux) {
    # Linux implementation with xclip/xsel
}
elseif ($IsMacOS) {
    # macOS implementation with pbcopy
}
```

### Long-Running Task Pattern
For reporting or batch operations, follow the pattern in `create-report/Invoke-WeatherReport.ps1`:
- **Logging**: Use `Start-Transcript` and `Stop-Transcript` for comprehensive logging
- **Progress tracking**: Display running counters (`Ok: $CountOk / Error: $CountError`)
- **Timing**: Use `[System.Diagnostics.Stopwatch]` for execution time tracking
- **Directory creation**: Auto-create `reports/` and `logs/` directories with timestamped files
- **Error handling**: Use try-catch blocks with detailed error counting

### Data File Conventions
- **JSON configuration**: Store structured data in JSON files alongside scripts (e.g., `wordlists.json`)
- **Sample data**: Provide `.json` sample data files for testing (e.g., `sample-data.json`)
- **Pipeline support**: Design functions to accept pipeline input with `[Parameter(ValueFromPipeline)]`

### Microsoft 365 Scripts
When developing scripts for Microsoft 365 (SharePoint, Teams, Graph, etc.), prefer the PnP PowerShell module:
- **Module**: Use PnP PowerShell (https://github.com/pnp/powershell) over other M365 modules
- **Documentation**: Reference valid cmdlets at https://pnp.github.io/powershell/cmdlets/
- **Authentication**: Use `Connect-PnPOnline` with appropriate auth methods
- **Patterns**: Follow examples in `spo-unique-permissions/` for SPO operations
- **Safety**: Include interactive confirmation for destructive operations
- **Progress**: Provide clear progress feedback for bulk operations

### Safety Confirmation Rule
- Any script that performs changes to (add/update/delete content, create/publish pages, upload files, modify metadata) must require an explicit user confirmation before proceeding.
- Recommended usage at the start of the mutation section of a script (after config is loaded and inputs are validated):
  - `Confirm-Continue -Message "This operation will modify SharePoint content (X items). Press any key to continue, or Ctrl+C to abort..."`
- For reporting/export-only scripts (read-only), the confirmation is not required.

## Development Workflow

### Testing Scripts
- Each directory should contain sample data or test scenarios
- Use the patterns: `Get-Content -Path .\sample-data.json | ConvertFrom-Json | Your-Function`
- Test cross-platform clipboard functionality on target platforms

### Adding New Scripts
1. Create a new directory for the functionality
2. Copy header template from `DefaultScriptHeader.ps1`
3. Include a README.md with usage examples
4. Add any required data files in the same directory
5. Follow the established error handling and logging patterns

### External Dependencies
- **SharePoint scripts**: Require PnP.PowerShell module
- **Cross-platform clipboard**: May require `xclip`/`xsel` on Linux
- Always document external dependencies in script comments and README files

## File Naming Conventions
- **Main scripts**: Use PascalCase with descriptive names (`CodeNameGenerator.ps1`, `Invoke-WeatherReport.ps1`)
- **Data files**: Use lowercase with hyphens (`sample-data.json`, `wordlists.json`)
- **Functions**: Use PowerShell approved verbs (`Get-`, `Invoke-`, `Set-`)