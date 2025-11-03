#Requires -Version 7

Function Invoke-WeatherReport
{
    <#
    .SYNOPSIS
        Generate a weather report and export to a CSV file
    .DESCRIPTION
        This sample includes:
        * Support for long running reporting tasks (hours or even days)
        * Stats and logging (saves output to log file using transcript)
        * Load sample data (from JSON - could be an external API)
        * Export report to CSV file (ordered)
    .EXAMPLE
        Get-Content -Path .\sample-data.json | ConvertFrom-Json | Invoke-Report
    .NOTES
        Author      : Are Flyen
    #>

    [CmdletBinding()]
    Param (
        # Param1 help description
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject]
        $WeatherItem
    )

    Begin
    {
        $Location = Get-Location
    
        # Report
        $ReportFileName = Join-Path $Location "reports/$([System.DateTime]::Now.Year)$([System.DateTime]::Now.Month)$([System.DateTime]::Now.Day)-$([System.DateTime]::Now.Hour)$([System.DateTime]::Now.Minute)$([System.DateTime]::Now.Second).csv"
        New-Item -ItemType Directory -Name "reports" -ErrorAction SilentlyContinue | Out-Null
        $Report = @()
    
        # Logging
        $LogFileName = Join-Path $Location "logs/$($MyInvocation.MyCommand.Name)-$([System.DateTime]::Now.Year)$([System.DateTime]::Now.Month)$([System.DateTime]::Now.Day)-$([System.DateTime]::Now.Hour)$([System.DateTime]::Now.Minute)$([System.DateTime]::Now.Second).txt"
        New-Item -ItemType Directory -Name "logs" -ErrorAction SilentlyContinue | Out-Null
    
        Start-Transcript -Path $LogFileName -NoClobber
    
        # Stats
        $Elapsed = [System.Diagnostics.Stopwatch]::StartNew()
        $CountOk = 0
        $CountError = 0
    }
    Process
    {
        Write-Host "`tCity: $($WeatherItem.city) / Ok: $($CountOk) / Error: $($CountError)"
    
        Try {
            # Create an ordered report item
            $ReportItem = [ordered]@{
                City = $WeatherItem.city
                Temperature =  $WeatherItem.temperature
                Description = $WeatherItem.description
            }
    
            # Skip items with this condition
            If ($WeatherItem.description -eq "Rain shower")
            {
                throw "Bad weather exception!"
                #return
            }
    
            # Add report item to report
            $Report += [PSCustomObject]$ReportItem
            $CountOk++
        }
        Catch {
            Write-Host "`t`tERROR: $($_.Exception.Message)"
            $CountError++
        }
    }
    End
    {
        Write-Host "Summary - OK: $($CountOk) - Failed: $($CountError)"
        Write-Host "Execution time - Hours: $($Elapsed.Elapsed.Hours) - Minutes: $($Elapsed.Elapsed.Minutes) / Seconds: $($Elapsed.Elapsed.Seconds)"

        # Export report to CSV file
        $Report | Export-Csv -Path $ReportFileName
    
        Stop-Transcript
    }
}