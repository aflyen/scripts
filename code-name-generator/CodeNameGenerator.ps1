<#
.SYNOPSIS
    Generates random project code names for testing purposes.

.DESCRIPTION
    Creates random 3-4 word code names using neutral words from predefined lists.
    The generated name is automatically copied to the clipboard.
    
    Code names follow patterns like:
    - "Blue Tiger Tokyo 2025"
    - "Red Elephant Paris"
    - "Green Dolphin Berlin 47"

.EXAMPLE
    .\CodeNameGenerator.ps1
    Generates and copies a random code name to clipboard.

.NOTES
     Author    : Are Flyen
     Date      : 03.11.2025
.LINK
     https://www.areflyen.no
#>

#Requires -Version 7.0

[CmdletBinding()]
param()

function Get-RandomCodeName {
    <#
    .SYNOPSIS
        Generates a random code name from word lists.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        # Get the script directory
        $scriptPath = $PSScriptRoot
        $wordListPath = Join-Path -Path $scriptPath -ChildPath 'wordlists.json'

        # Check if word list file exists
        if (-not (Test-Path -Path $wordListPath)) {
            throw "Word list file not found at: $wordListPath"
        }

        # Load word lists from JSON
        Write-Verbose "Loading word lists from: $wordListPath"
        $wordLists = Get-Content -Path $wordListPath -Raw | ConvertFrom-Json

        # Define possible patterns for code names
        $patterns = [System.Collections.Generic.List[string[]]]::new()
        $patterns.Add(@('colors', 'animals', 'locations'))           # Blue Tiger Tokyo
        $patterns.Add(@('colors', 'animals', 'locations', 'number')) # Blue Tiger Tokyo 2025
        $patterns.Add(@('adjectives', 'animals', 'locations'))       # Swift Eagle Berlin
        $patterns.Add(@('colors', 'nouns', 'locations'))             # Red Summit Paris
        $patterns.Add(@('adjectives', 'nouns', 'locations', 'number')) # Bold Horizon Tokyo 42

        # Select a random pattern
        $randomIndex = Get-Random -Minimum 0 -Maximum $patterns.Count
        $selectedPattern = $patterns[$randomIndex]

        # Build the code name
        $codeNameParts = [System.Collections.Generic.List[string]]::new()

        foreach ($wordType in $selectedPattern) {
            if ($wordType -eq 'number') {
                # Generate random number (either a year-like or simple number)
                $numberStyle = Get-Random -Minimum 1 -Maximum 3
                $number = switch ($numberStyle) {
                    1 { Get-Random -Minimum 2025 -Maximum 2035 }  # Year
                    2 { Get-Random -Minimum 1 -Maximum 100 }       # Simple number
                }
                $codeNameParts.Add($number.ToString())
            }
            else {
                # Get random word from the specified list
                $wordList = $wordLists.$wordType
                if ($null -eq $wordList -or $wordList.Count -eq 0) {
                    throw "Word list '$wordType' is empty or not found"
                }
                $randomWord = $wordList | Get-Random
                $codeNameParts.Add($randomWord)
            }
        }

        # Join parts with spaces
        $codeName = $codeNameParts -join ' '
        
        Write-Verbose "Generated code name: $codeName"
        return $codeName
    }
    catch {
        Write-Error "Failed to generate code name: $_"
        throw
    }
}

function Copy-ToClipboard {
    <#
    .SYNOPSIS
        Copies text to the clipboard in a cross-platform way.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    try {
        if ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6 -or $null -eq $IsWindows) {
            # Windows
            Set-Clipboard -Value $Text
        }
        elseif ($IsLinux) {
            # Linux - requires xclip or xsel
            if (Get-Command xclip -ErrorAction SilentlyContinue) {
                $Text | xclip -selection clipboard
            }
            elseif (Get-Command xsel -ErrorAction SilentlyContinue) {
                $Text | xsel --clipboard --input
            }
            else {
                Write-Warning "Clipboard functionality requires 'xclip' or 'xsel' on Linux"
                return $false
            }
        }
        elseif ($IsMacOS) {
            # macOS
            $Text | pbcopy
        }
        return $true
    }
    catch {
        Write-Warning "Failed to copy to clipboard: $_"
        return $false
    }
}

# Main script execution
try {
    Write-Host "Generating project code name..." -ForegroundColor Cyan

    # Generate the code name
    $codeName = Get-RandomCodeName

    # Display the code name
    Write-Host "`nGenerated Code Name: " -NoNewline -ForegroundColor Green
    Write-Host $codeName -ForegroundColor Yellow -BackgroundColor DarkBlue

    # Copy to clipboard
    $copied = Copy-ToClipboard -Text $codeName

    if ($copied) {
        Write-Host "`n✓ Copied to clipboard!" -ForegroundColor Green
    }
    else {
        Write-Host "`nℹ Code name ready to copy manually" -ForegroundColor Yellow
    }
}
catch {
    Write-Error "An error occurred: $_"
    exit 1
}
