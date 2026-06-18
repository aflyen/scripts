# New-DevSelfSignedCert.ps1

A PowerShell script that generates a self-signed development certificate for Windows with a 2-year validity period and exports it to both `.cer` and `.pfx` formats. The files will be placed in the users OneDrive storage if no other location is specified.

**Primary Use Case:** Certificate-based authentication with PnP PowerShell for Microsoft 365 / SharePoint Online app registrations for development.

## Features

- ✅ Creates a self-signed certificate valid for 2 years
- ✅ Exports public certificate (`.cer`) and private key (`.pfx`)
- ✅ PFX export requires **no password**
- ✅ Configurable certificate name (defaults to "AFLYEN DEV")
- ✅ Configurable output path (defaults to OneDrive)
- ✅ Auto-detects OneDrive location (`$env:OneDrive`, `$env:OneDriveCommercial`, `$env:OneDriveConsumer`)
- ✅ Uses SHA256 and RSA 2048-bit encryption
- ✅ Certificate stored in `Cert:\CurrentUser\My`

## Prerequisites

- Windows PowerShell 5.0+ or PowerShell Core
- User account with permissions to create certificates
- (Optional) OneDrive configured for auto-export to work

## Parameters

### `-Name` (string, optional)
The friendly name and subject for the certificate.
- **Default:** `"AFLYEN DEV"`
- **Example:** `-Name "My Custom Cert"`

### `-OutputPath` (string, optional)
Directory where `.cer` and `.pfx` files will be exported.
- **Default:** Auto-detects OneDrive location
- **Example:** `-OutputPath "C:\Certificates"`
- If neither parameter nor OneDrive is found, the script throws an error.

## Usage

### Basic (default name, export to OneDrive)
```powershell
powershell -ExecutionPolicy Bypass -File .\New-DevSelfSignedCert.ps1
```

### Custom certificate name
```powershell
powershell -ExecutionPolicy Bypass -File .\New-DevSelfSignedCert.ps1 -Name "MyDevCert"
```

### Custom output location
```powershell
powershell -ExecutionPolicy Bypass -File .\New-DevSelfSignedCert.ps1 -OutputPath "C:\temp\certs"
```

### Custom name and location
```powershell
powershell -ExecutionPolicy Bypass -File .\New-DevSelfSignedCert.ps1 -Name "WebDev" -OutputPath "D:\exports"
```

## Output

The script produces:

1. **Console Output:**
   - Certificate name
   - Thumbprint (identifier)
   - Certificate store location
   - Expiration date
   - Export file paths

2. **Files:**
   - `<Name>.cer` - Public certificate (can be imported into trust stores)
   - `<Name>.pfx` - Private key + public cert (password-free, for import into applications)

### Example Output
```
Created self-signed development certificate.
Name: AFLYEN DEV
Thumbprint: A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R8S9T0
Store Path: Cert:\CurrentUser\My
Valid Until: 2028-06-18 00:00:00Z
Exported CER: C:\Users\YourUser\OneDrive\AFLYEN-DEV.cer
Exported PFX: C:\Users\YourUser\OneDrive\AFLYEN-DEV.pfx
```

## Important Notes

### Trust Store
This script stores the certificate in **CurrentUser\My** only. It does **not** automatically import the certificate to the Trusted Root store.

To establish **machine-wide trust** (so browsers/applications trust it without warnings), manually import the `.cer` file:

**PowerShell (as Administrator):**
```powershell
Import-Certificate -FilePath "path\to\cert.cer" -CertStoreLocation "Cert:\LocalMachine\Root"
```

**Windows Certificate Manager:**
1. Run `certmgr.msc`
2. Navigate to **Trusted Root Certification Authorities > Certificates**
3. Right-click → **All Tasks** → **Import**
4. Select the `.cer` file

### Important Notes
The exported `.pfx` file has **no password protection**. This is by design for development convenience. Do **not** use this for production certificates.

### Special Characters in Names
Certificate names with special characters (`\ / : * ? " < > |`) are automatically sanitized in exported filenames (replaced with `-`).

For example:
- Name: `"My/Dev:Cert"`
- Files: `My-Dev-Cert.cer` and `My-Dev-Cert.pfx`

## Troubleshooting

| Issue | Solution |
|-------|----------|
| **"OneDrive was not found"** | Provide `-OutputPath` explicitly or configure OneDrive |
| **"Certificate creation failed"** | Ensure you have permissions to create certificates; try running as admin |
| **Certificate not trusted by browser** | Import the `.cer` to `LocalMachine\Root` (see Trust Store section above) |
| **Cannot export PFX** | Verify the `-OutputPath` directory exists and is writable |

## Related Scripts

- **GenerateCert.ps1**: Original version with hard-coded name, localhost DNS, and automatic trust setup
