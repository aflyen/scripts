<# .SYNOPSIS
     Find all files in document library with unique permissions and reset them
.DESCRIPTION
     Loops through all files in a document library in SharePoint Online 
     and checks if the file contains unique permissions. After locating all the files 
     you are asked to continue to reset the permissions back to inherting from the top 
     level permissions in the library.
.NOTES
     Author    : Are Flyen
     Date      : 24.03.2023
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

if ($Files.Count -eq 0)
{
     break
}

$Files | ForEach-Object { Write-Output "Filename: $($_.FieldValues.FileLeafRef)" }

Write-Host "Reset file permissions?"
Write-Host "Press [ENTER] to contiune"
Read-Host

foreach ($File in $Files) {
     Write-Output "`tResetting: $($File.FieldValues.FileLeafRef)"

     # Reset permissions to inherit from library
     Set-PnPListItemPermission -List $ListName -Identity $File.Id -InheritPermissions
}