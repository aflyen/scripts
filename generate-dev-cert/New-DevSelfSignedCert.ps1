param(
    [Parameter(Mandatory = $false)]
    [string]$Name = "AFLYEN DEV",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

# Creates a local-machine self-signed certificate for development use.
$certStorePath = "Cert:\CurrentUser\My"
$certFriendlyName = $Name
$certDnsName = $Name
$validTo = (Get-Date).AddYears(2)

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $candidatePaths = @(
        $env:OneDrive,
        $env:OneDriveCommercial,
        $env:OneDriveConsumer
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if ($candidatePaths.Count -eq 0) {
        throw "No output path was provided, and OneDrive was not found in this user profile. Provide -OutputPath explicitly."
    }

    $OutputPath = $candidatePaths[0]
}

if (-not (Test-Path -Path $OutputPath -PathType Container)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

$safeName = $Name -replace '[\\/:*?"<>|]', '-'
$cerPath = Join-Path -Path $OutputPath -ChildPath "$safeName.cer"
$pfxPath = Join-Path -Path $OutputPath -ChildPath "$safeName.pfx"

$newCertParams = @{
    Subject           = "CN=$Name"
    DnsName           = $certDnsName
    FriendlyName      = $certFriendlyName
    CertStoreLocation = $certStorePath
    NotAfter          = $validTo
    HashAlgorithm     = "SHA256"
    KeyAlgorithm      = "RSA"
    KeyLength         = 2048
    KeyExportPolicy   = "Exportable"
}

$cert = New-SelfSignedCertificate @newCertParams

if (-not $cert) {
    throw "Certificate creation failed."
}

Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null

$emptyPassword = New-Object System.Security.SecureString
Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $emptyPassword | Out-Null

Write-Host "Created self-signed development certificate."
Write-Host "Name: $Name"
Write-Host "Thumbprint: $($cert.Thumbprint)"
Write-Host "Store Path: $certStorePath"
Write-Host "Valid Until: $($cert.NotAfter.ToString('u'))"
Write-Host "Exported CER: $cerPath"
Write-Host "Exported PFX: $pfxPath"
