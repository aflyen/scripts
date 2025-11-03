<# .SYNOPSIS
     Find all files in document library with unique permissions
.DESCRIPTION
     Loops through all files in a document library in SharePoint Online 
     and checks if the file contains unique permissions. Gives output
     to the console.
.NOTES
     Author    : Are Flyen
     Date      : 23.03.2023
.LINK
     https://www.areflyen.no
#>

# Setup
$SiteUrl = "https://contoso.sharepoint.com/sites/teamsite1"
$ListName = "Documents"

# Connect to site
Connect-PnPOnline -Url $SiteUrl -Interactive

# Get files with unique permissions
$Files = Get-PnPListItem -List $ListName | Where-Object { (Get-PnPProperty -ClientObject $_ -Property HasUniqueRoleAssignments) -eq $true }

Write-Output "Files with unique permissions: $($Files.Count)"

$Files | ForEach-Object { Write-Output "Filename: $($_.FieldValues.FileLeafRef)" }
