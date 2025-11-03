# Create report

Generate a report and export to a CSV file using PowerShell

This script sample includes:

* Support for long running reporting tasks (hours or even days)
* Stats and logging (saves output to log file using transcript)
* Load sample data (from JSON - could be an external API)
* Export report to CSV file (ordered)

## Example

```powershell
. ./Invoke-WeatherReport.ps1
Get-Content -Path .\sample-data.json | ConvertFrom-Json | Invoke-WeatherReport
```