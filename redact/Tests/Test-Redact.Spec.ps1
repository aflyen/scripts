#Requires -Version 7.0
<#
.SYNOPSIS
  Independent black-box tests for Redact.ps1, written from README.md and mapping.example.json only.
  The implementation source was never inspected.

.DESCRIPTION
  Every test runs Redact.ps1 in a child pwsh process (so COMPUTERNAME / USERNAME / REDACT_MAPPING can be
  controlled), each with its own temp folder containing its own mapping.json.

  Updated when restore and the persisted mapping.auto.json were removed: the tool is now one-way and
  stateless, so restore/round-trip tests were replaced by stateless and realistic-log leak tests.

  Category tags:
    SPEC        behaviour explicitly described in README.md / mapping.example.json
    EXPECTATION what a careful, security-minded user would reasonably expect but the README does not state
  Kind tags (for triage): LEAK, FP (false positive / info destroyed), MAPPING, MISC

  Fake secrets are assembled at runtime from fragments so this file contains no scannable tokens.

.EXAMPLE
  pwsh -File .\Tests\Test-Redact.Spec.ps1
  pwsh -File .\Tests\Test-Redact.Spec.ps1 -Filter '*stateless*'
#>
[CmdletBinding()]
param(
    [string]$ScriptPath     = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Redact.ps1'),
    [string]$ExampleMapping = (Join-Path (Split-Path $PSScriptRoot -Parent) 'mapping.example.json'),
    [string]$Filter         = '*',
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

$ScriptPath     = (Resolve-Path -LiteralPath $ScriptPath).Path
$ExampleMapping = (Resolve-Path -LiteralPath $ExampleMapping).Path
$Utf8 = [Text.UTF8Encoding]::new($false)

$Pwsh = [Environment]::ProcessPath
if (-not $Pwsh -or (Split-Path $Pwsh -Leaf) -notmatch '^pwsh') {
    $Pwsh = Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')
}

$Root = Join-Path ([IO.Path]::GetTempPath()) ('redact-spec-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Root -Force | Out-Null

# ---------------------------------------------------------------------------------------------
# Child-process runner: mimics "PS> .\Redact.ps1 ... > out.txt" — only the success stream is the
# result; warnings / information / errors go to stderr.
# ---------------------------------------------------------------------------------------------
$Runner = Join-Path $Root 'runner.ps1'
@'
param([string]$Script, [string]$InFile, [string]$Map, [switch]$NoMap)
$enc = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $enc
$OutputEncoding = $enc
$h = @{ NoClipboard = $true; Quiet = $true }
if ($InFile)     { $h.Path = $InFile }
if (-not $NoMap) { $h.MappingPath = $Map }
$global:LASTEXITCODE = 0
$failed = $false
try {
    & $Script @h 2>&1 3>&1 6>&1 | ForEach-Object {
        if     ($_ -is [System.Management.Automation.WarningRecord])     { [Console]::Error.WriteLine('WARNING: ' + $_.Message) }
        elseif ($_ -is [System.Management.Automation.InformationRecord]) { [Console]::Error.WriteLine('INFO: ' + $_.MessageData) }
        elseif ($_ -is [System.Management.Automation.ErrorRecord])       { $failed = $true; [Console]::Error.WriteLine('ERROR: ' + $_) }
        else { [Console]::Out.WriteLine([string]$_) }
    }
} catch {
    [Console]::Error.WriteLine('TERMINATING: ' + $_)
    exit 99
}
if ($LASTEXITCODE) { exit $LASTEXITCODE }
if ($failed) { exit 1 }
exit 0
'@ | Set-Content -LiteralPath $Runner -Encoding utf8

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------
$script:CtxCounter = 0
$script:InCounter  = 0
$script:Trace      = [Collections.Generic.List[string]]::new()

function New-Mapping {
    param([object[]]$Replacements = @(), [object[]]$Patterns = @(), [object[]]$SecretPatterns = @(), [string[]]$Ignore = @())
    [ordered]@{ replacements = @($Replacements); patterns = @($Patterns); secretPatterns = @($SecretPatterns); ignore = @($Ignore) }
}

function New-Ctx {
    # $Mapping: $null => copy of mapping.example.json; [string] => raw JSON; otherwise serialised object
    param($Mapping = $null, [string]$SubDir = '')
    $script:CtxCounter++
    $d = Join-Path $Root ('t{0:D3}' -f $script:CtxCounter)
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $mapDir = $SubDir ? (Join-Path $d $SubDir) : $d
    New-Item -ItemType Directory -Path $mapDir -Force | Out-Null
    $m = Join-Path $mapDir 'mapping.json'
    if ($null -eq $Mapping)      { Copy-Item -LiteralPath $ExampleMapping -Destination $m }
    elseif ($Mapping -is [string]) { [IO.File]::WriteAllText($m, $Mapping, $Utf8) }
    else                         { [IO.File]::WriteAllText($m, ($Mapping | ConvertTo-Json -Depth 10), $Utf8) }
    [pscustomobject]@{ Dir = $d; Map = $m; MapDir = $mapDir }
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)] $Ctx,
        [AllowEmptyString()] [string]$Text = '',
        [hashtable]$EnvVars, [string]$MapArg, [switch]$NoMap, [string]$WorkDir
    )
    $script:InCounter++
    $in = Join-Path $Ctx.Dir ('in{0:D4}.txt' -f $script:InCounter)
    [IO.File]::WriteAllText($in, ($Text -replace "`r`n", "`n"), $Utf8)

    $psi = [Diagnostics.ProcessStartInfo]::new($Pwsh)
    foreach ($a in '-NoProfile', '-NonInteractive', '-File', $Runner, '-Script', $ScriptPath, '-InFile', $in) { $psi.ArgumentList.Add($a) }
    if ($NoMap) { $psi.ArgumentList.Add('-NoMap') }
    else { $psi.ArgumentList.Add('-Map'); $psi.ArgumentList.Add(($MapArg ? $MapArg : $Ctx.Map)) }
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding  = $Utf8
    $psi.WorkingDirectory       = $WorkDir ? $WorkDir : $Ctx.Dir
    [void]$psi.Environment.Remove('REDACT_MAPPING')
    $defaults = @{ COMPUTERNAME = 'WS-TESTBOX77'; USERNAME = 'kjetilh'; USER = 'kjetilh' }
    foreach ($k in $defaults.Keys) { $psi.Environment[$k] = $defaults[$k] }
    if ($EnvVars) {
        foreach ($k in $EnvVars.Keys) {
            if ($null -eq $EnvVars[$k]) { [void]$psi.Environment.Remove($k) } else { $psi.Environment[$k] = [string]$EnvVars[$k] }
        }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(240000)) { try { $p.Kill($true) } catch {}; throw 'Tool timed out after 240s' }
    $p.WaitForExit()
    $sw.Stop()
    $out = ($o.Result -replace "`r`n", "`n").TrimEnd("`n")
    $err = ($e.Result -replace "`r`n", "`n").Trim()
    $r = [pscustomobject]@{ Out = $out; Err = $err; Code = $p.ExitCode; Ms = $sw.ElapsedMilliseconds }
    $script:Trace.Add(("--- input:`n{0}`n--- stdout (exit {1}):`n{2}{3}" -f $Text, $r.Code, $r.Out, ($r.Err ? "`n--- stderr:`n$($r.Err)" : '')))
    $r
}

function Redact {
    param([Parameter(Mandatory)] $Ctx, [AllowEmptyString()] [string]$Text, [hashtable]$EnvVars)
    $r = Invoke-Tool -Ctx $Ctx -Text $Text -EnvVars $EnvVars
    if ($r.Code -ne 0) { throw "Tool exited with code $($r.Code). stderr: $($r.Err)" }
    $r.Out
}

function Test-HasError($r) {
    ($r.Code -ne 0) -or ($r.Err -match '(?i)ERROR:|TERMINATING:|exception')
}

function Assert-NoLeak([string]$Actual, [string[]]$Forbidden) {
    foreach ($f in $Forbidden) {
        if ($f -and $Actual.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "LEAK: output contains '$f'" }
    }
}
function Assert-Has([string]$Actual, [string[]]$Required, [switch]$CI) {
    $cmp = $CI ? [StringComparison]::OrdinalIgnoreCase : [StringComparison]::Ordinal
    foreach ($q in $Required) { if ($Actual.IndexOf($q, $cmp) -lt 0) { throw "MISSING: output does not contain '$q'" } }
}
function Assert-Exact([string]$Actual, [string]$Expected) {
    $a = ($Actual -replace "`r`n", "`n").TrimEnd("`n")
    $x = ($Expected -replace "`r`n", "`n").TrimEnd("`n")
    if ($a -cne $x) {
        $i = 0; while ($i -lt [Math]::Min($a.Length, $x.Length) -and $a[$i] -ceq $x[$i]) { $i++ }
        throw "MISMATCH at char $i`n  expected: $x`n  actual:   $a"
    }
}
function Assert-True([bool]$Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }
function Hide([string]$s) {
    # the whole secret plus a distinctive middle slice (catches partial redaction)
    if ($s.Length -ge 20) { @($s, $s.Substring([int]($s.Length / 2) - 6, 12)) } else { @($s) }
}
function L { $args -join "`n" }

# ---------------------------------------------------------------------------------------------
# Fake secret material (assembled at runtime)
# ---------------------------------------------------------------------------------------------
$rng = [Random]::new(20261011)
function Rnd([string]$Set, [int]$N) { -join (1..$N | ForEach-Object { $Set[$rng.Next($Set.Length)] }) }
$ALNUM = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
$UPNUM = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
$B32   = 'abcdefghijklmnopqrstuvwxyz234567'
$HEX   = '0123456789abcdef'
$HEXU  = '0123456789ABCDEF'
$B64   = $ALNUM + '+/'
$B64U  = $ALNUM + '-_'

$Sec = [ordered]@{
    Ghp     = ('gh' + 'p_') + (Rnd $ALNUM 36)
    Ghs     = ('gh' + 's_') + (Rnd $ALNUM 36)
    GhPat   = ('github' + '_pat_') + (Rnd $ALNUM 22) + '_' + (Rnd $ALNUM 59)
    Aws     = ('AK' + 'IA') + (Rnd $UPNUM 16)
    Entra   = (Rnd $ALNUM 3) + '8' + ('Q' + '~') + (Rnd ($ALNUM + '_-.') 34)
    Pat52   = Rnd $B32 52
    Pat84   = (Rnd $ALNUM 76) + ('AZ' + 'DO') + (Rnd $ALNUM 4)
    StorKey = (Rnd $ALNUM 1) + (Rnd $B64 85) + '=='
    StorKey2= (Rnd $ALNUM 1) + (Rnd $B64 85) + '=='
    Jwt     = ('ey' + 'J') + (Rnd $B64U 34) + '.' + ('ey' + 'J') + (Rnd $B64U 80) + '.' + (Rnd $B64U 43)
    Opaque  = Rnd $ALNUM 48
    Basic   = [Convert]::ToBase64String($Utf8.GetBytes('svc-deploy:' + 'Vinter' + '2026!x'))
    Sig     = (Rnd $ALNUM 30) + '%2B' + (Rnd $ALNUM 10) + '%3D'
    Apim    = Rnd $HEX 32
    ApiKey  = Rnd $ALNUM 40
    SqlPw   = 'Vinter' + '2026!Qx'
    UrlPw   = 'Hunter' + '2Pass99'
    Generic = 'Zq' + (Rnd $ALNUM 18)
    FuncKey = (Rnd ($ALNUM + '_-') 54) + '=='
    SbKey   = (Rnd $B64 43) + '='
    Webhook = Rnd $HEX 32
    PubPw   = Rnd $ALNUM 60
}
function New-PemBlock([string]$Label) {
    $lines = 1..4 | ForEach-Object { Rnd $B64 64 }
    L ('-----BEGIN ' + $Label + '-----') @lines ('-----END ' + $Label + '-----')
}
$Pem = [ordered]@{
    Pkcs8     = New-PemBlock ('PRIVATE' + ' KEY')
    Rsa       = New-PemBlock ('RSA PRIVATE' + ' KEY')
    OpenSsh   = New-PemBlock ('OPENSSH PRIVATE' + ' KEY')
    Encrypted = New-PemBlock ('ENCRYPTED PRIVATE' + ' KEY')
}
$Thumb  = Rnd $HEXU 40
$Thumb2 = Rnd $HEXU 40
$GitSha = '9fceb02d0ae598e95dc970b74767f19372d61af8'

$G = [ordered]@{
    Tenant = 'a1b2c3d4-1111-4222-8333-444455556666'
    App    = '9b8a7c6d-aaaa-4bbb-8ccc-111122223333'
    Sub    = 'aaaabbbb-cccc-4ddd-8eee-ffff00001111'
    Req    = '5e6f7a8b-1234-4cde-8f00-abcdefabcdef'
    Req2   = '5e6f7a8b-1234-4cde-8f00-abcdefabcde0'
    Inv    = '0f1e2d3c-4b5a-4978-8796-a5b4c3d2e1f0'
    AiKey  = '3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f'
}
$Ph = @{ G1 = '00000000-0000-0000-0000-000000000001'; G2 = '00000000-0000-0000-0000-000000000002' }

# ---------------------------------------------------------------------------------------------
# Test registry
# ---------------------------------------------------------------------------------------------
$Tests = [Collections.Generic.List[object]]::new()
function T([string]$Name, [ValidateSet('SPEC', 'EXPECTATION')] [string]$Cat, [string]$Kind, [scriptblock]$Body, [object]$Data = $null) {
    # $Data is exposed to the body as $D (set by the runner just before the body is invoked)
    $Tests.Add([pscustomobject]@{ Name = $Name; Cat = $Cat; Kind = $Kind; Body = $Body; Data = $Data })
}

# helper for the common "secret must vanish, <redacted:...> must appear" shape
function Test-Secret([string]$Template, [string]$Value, [string[]]$MustKeep = @(), [string[]]$ExtraForbidden = @()) {
    $c = New-Ctx
    $out = Redact $c $Template.Replace('@@', $Value)
    Assert-NoLeak $out ((Hide $Value) + $ExtraForbidden)
    Assert-Has $out '<redacted:'
    if ($MustKeep) { Assert-Has $out $MustKeep }
}

# =============================================================================================
# 1. SECRETS (README "Rules" 1)
# =============================================================================================
T 'secret: JWT (bare, no keyword)' SPEC LEAK { Test-Secret 'Decoded @@ from cache' $Sec.Jwt -MustKeep 'from cache' }
T 'secret: Authorization Bearer (opaque)' SPEC LEAK { Test-Secret 'Authorization: Bearer @@' $Sec.Opaque }
T 'secret: Authorization Bearer (JWT) in JSON header dump' SPEC LEAK { Test-Secret '{"Authorization":"Bearer @@","Accept":"application/json"}' $Sec.Jwt -MustKeep '"Accept":"application/json"' }
T 'secret: Authorization Basic' SPEC LEAK { Test-Secret 'Authorization: Basic @@' $Sec.Basic }
T 'secret: GitHub ghp_ (bare)' SPEC LEAK { Test-Secret 'git push using @@ failed' $Sec.Ghp }
T 'secret: GitHub github_pat_ (bare)' SPEC LEAK { Test-Secret 'echo @@ | gh auth login' $Sec.GhPat }
T 'secret: AWS AKIA (bare)' SPEC LEAK { Test-Secret 'Using @@ for s3 sync' $Sec.Aws }
T 'secret: Entra client secret Q~ (bare)' SPEC LEAK { Test-Secret 'New credential @@ created for app' $Sec.Entra }
T 'secret: Azure DevOps PAT 52 chars (bare)' SPEC LEAK { Test-Secret 'echo @@ | az devops login' $Sec.Pat52 }
T 'secret: Azure DevOps PAT 84 chars (bare)' SPEC LEAK { Test-Secret 'echo @@ | az devops login' $Sec.Pat84 }
T 'secret: bare storage key 88 chars ==' SPEC LEAK { Test-Secret 'key1  FULL  @@' $Sec.StorKey }
T 'secret: storage key in az CLI JSON output' SPEC LEAK { Test-Secret '[{"keyName":"key1","permissions":"FULL","value":"@@"}]' $Sec.StorKey2 -MustKeep '"keyName":"key1"' }
T 'secret: AccountKey= in storage connection string' SPEC LEAK {
    Test-Secret 'DefaultEndpointsProtocol=https;AccountName=stlogs8842;AccountKey=@@;EndpointSuffix=core.windows.net' $Sec.StorKey -MustKeep 'EndpointSuffix=core.windows.net' -ExtraForbidden 'stlogs8842'
}
T 'secret: Password= in SQL connection string, stops at ;' SPEC LEAK {
    Test-Secret 'Server=tcp:sql-acme.database.windows.net,1433;User ID=sqladmin;Password=@@;Encrypt=True;' $Sec.SqlPw -MustKeep 'Encrypt=True'
}
T 'secret: SAS sig= in blob URL' SPEC LEAK {
    Test-Secret 'https://stlogs8842.blob.core.windows.net/export/a.csv?sv=2022-11-02&ss=b&srt=o&sp=r&se=2026-12-31T23:59:59Z&sig=@@' $Sec.Sig -MustKeep 'sv=2022-11-02'
}
T 'secret: SAS sig= in Logic App trigger URL' SPEC LEAK {
    Test-Secret 'POST https://prod-12.westeurope.logic.azure.com:443/workflows/abc/triggers/manual/paths/invoke?api-version=2016-06-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=@@' $Sec.Sig
}
T 'secret: user:pass@ in URL' SPEC LEAK { Test-Secret 'POST https://deploy:@@@func-acme.scm.azurewebsites.net/api/zipdeploy' $Sec.UrlPw }
T 'secret: GitHub server token in x-access-token:...@ clone URL' SPEC LEAK { Test-Secret 'git clone https://x-access-token:@@@github.com/acme/infra.git' $Sec.Ghs }
T 'secret: ADO PAT in git remote user:pass@' SPEC LEAK { Test-Secret 'git remote add origin https://build:@@@dev.azure.com/acmeorg/Intranet/_git/web' $Sec.Pat52 }
T 'secret: x-api-key header' SPEC LEAK { Test-Secret 'x-api-key: @@' $Sec.ApiKey }
T 'secret: Ocp-Apim-Subscription-Key header' SPEC LEAK { Test-Secret 'Ocp-Apim-Subscription-Key: @@' $Sec.Apim }
T 'secret: key/value password quoted with spaces' SPEC LEAK { Test-Secret 'password: "@@"' 'correct horse battery staple' -ExtraForbidden 'horse', 'battery', 'staple' }
T 'secret: key/value password single-quoted with spaces' SPEC LEAK { Test-Secret "password = '@@'" 'correct horse battery staple' -ExtraForbidden 'horse', 'battery', 'staple' }
T 'secret: key/value secret=' SPEC LEAK { Test-Secret 'secret=@@' $Sec.Generic }
T 'secret: key/value clientSecret in JSON, other keys kept' SPEC LEAK { Test-Secret '{"clientId":"app","clientSecret":"@@","tenant":"t1"}' $Sec.Generic -MustKeep '"tenant":"t1"' }
T 'secret: key/value apiKey unquoted, stops at &' SPEC LEAK { Test-Secret 'GET /v1/data?apiKey=@@&format=json' $Sec.Generic -MustKeep '&format=json' }
T 'secret: key/value token:' SPEC LEAK { Test-Secret 'token: @@' $Sec.Generic }
T 'secret: unquoted value stops at ;' SPEC LEAK { Test-Secret 'password=@@;Encrypt=True' $Sec.Generic -MustKeep ';Encrypt=True' }
T 'secret: unquoted value stops at }' SPEC LEAK { Test-Secret '@{password=@@}' $Sec.Generic -MustKeep '}' }
T 'secret: unquoted value stops at ,' SPEC LEAK { Test-Secret 'password=@@, user=svc' $Sec.Generic -MustKeep ', user=svc' }
T 'secret: unquoted value stops at end of line, next line kept' SPEC LEAK { Test-Secret (L 'password: @@' 'next line here') $Sec.Generic -MustKeep 'next line here' }
T 'secret: YAML indented password:' SPEC LEAK { Test-Secret (L 'db:' '  user: app' '  password: @@' '  port: 5432') $Sec.Generic -MustKeep 'port: 5432' }
T 'secret: PowerShell hashtable ClientSecret = quoted' SPEC LEAK { Test-Secret "`$p = @{ ClientId = 'x'; ClientSecret = '@@' }" $Sec.Entra }
T 'secret: private key block (PKCS8)' SPEC LEAK {
    $c = New-Ctx; $body = ($Pem.Pkcs8 -split "`n")[1..4]
    $out = Redact $c (L 'cert follows:' $Pem.Pkcs8 'done')
    Assert-NoLeak $out $body; Assert-Has $out '<redacted:', 'done'
}
T 'secret: private key block (RSA)' SPEC LEAK {
    $c = New-Ctx; $body = ($Pem.Rsa -split "`n")[1..4]
    $out = Redact $c $Pem.Rsa; Assert-NoLeak $out $body; Assert-Has $out '<redacted:'
}
T 'secret: private key block (OPENSSH)' SPEC LEAK {
    $c = New-Ctx; $body = ($Pem.OpenSsh -split "`n")[1..4]
    $out = Redact $c $Pem.OpenSsh; Assert-NoLeak $out $body; Assert-Has $out '<redacted:'
}
T 'secret: private key block (ENCRYPTED)' SPEC LEAK {
    $c = New-Ctx; $body = ($Pem.Encrypted -split "`n")[1..4]
    $out = Redact $c $Pem.Encrypted; Assert-NoLeak $out $body; Assert-Has $out '<redacted:'
}
T 'secret: custom secretPattern vault-ref from example mapping' SPEC LEAK {
    $c = New-Ctx
    $out = Redact $c '"DbPassword": "@Microsoft.KeyVault(SecretUri=https://kv-acme.vault.azure.net/secrets/db-pass/)"'
    Assert-NoLeak $out 'kv-acme', 'db-pass'
    Assert-Has $out '<redacted:'
}
T 'secret: custom secretPattern produces <redacted:vault-ref>' SPEC MISC {
    $c = New-Ctx
    $out = Redact $c 'Setting=@Microsoft.KeyVault(SecretUri=https://kv-acme.vault.azure.net/secrets/x/)'
    Assert-Has $out '<redacted:vault-ref>'
}

# secrets in forms the README does not list (adversarial)
T 'leak: publish profile userPWD attribute' EXPECTATION LEAK {
    Test-Secret '<publishProfile publishUrl="func-acme.scm.azurewebsites.net:443" userName="$func-acme" userPWD="@@" />' $Sec.PubPw
}
T 'leak: web.config <add key="ClientSecret" value="..."/>' EXPECTATION LEAK { Test-Secret '<add key="ClientSecret" value="@@" />' $Sec.Generic }
T 'leak: PnP -ClientSecret parameter' EXPECTATION LEAK { Test-Secret "Connect-PnPOnline -Url https://acme.sharepoint.com -ClientId x -ClientSecret '@@'" $Sec.Generic }
T 'leak: OAuth form body client_secret=' EXPECTATION LEAK { Test-Secret 'grant_type=client_credentials&client_id=x&client_secret=@@&scope=https%3A%2F%2Fgraph.microsoft.com%2F.default' $Sec.Generic }
T 'leak: AZURE_CLIENT_SECRET env var' EXPECTATION LEAK { Test-Secret 'AZURE_CLIENT_SECRET=@@' $Sec.Generic }
T 'leak: Service Bus SharedAccessKey=' EXPECTATION LEAK { Test-Secret 'Endpoint=sb://sb-acme.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=@@' $Sec.SbKey }
T 'leak: Azure Function key in ?code=' EXPECTATION LEAK { Test-Secret 'GET https://func-acme.azurewebsites.net/api/Sync?code=@@' $Sec.FuncKey }
T 'leak: x-functions-key header' EXPECTATION LEAK { Test-Secret 'x-functions-key: @@' $Sec.FuncKey }
T 'leak: ConvertTo-SecureString -AsPlainText literal' EXPECTATION LEAK { Test-Secret "`$pw = ConvertTo-SecureString '@@' -AsPlainText -Force" $Sec.Generic }
T 'leak: access_token / refresh_token in token response JSON' EXPECTATION LEAK {
    $c = New-Ctx; $rt = Rnd $ALNUM 50
    $out = Redact $c ('{"token_type":"Bearer","expires_in":3599,"access_token":"' + $Sec.Opaque + '","refresh_token":"' + $rt + '"}')
    Assert-NoLeak $out ((Hide $Sec.Opaque) + (Hide $rt))
}
T 'leak: PASSWORD= uppercase key' EXPECTATION LEAK { Test-Secret 'PASSWORD=@@' $Sec.Generic }
T 'leak: Pwd= in ODBC connection string' EXPECTATION LEAK { Test-Secret 'Driver={ODBC Driver 18 for SQL Server};Server=sql1;Uid=app;Pwd=@@;' $Sec.Generic }
T 'leak: curl -u user:pass' EXPECTATION LEAK { Test-Secret 'curl -u deploy:@@ https://func-acme.scm.azurewebsites.net/api/zipdeploy' $Sec.UrlPw }
T 'leak: Teams incoming webhook URL secret segment' EXPECTATION LEAK {
    Test-Secret ('https://acme.webhook.office.com/webhookb2/' + $G.Tenant + '@' + $G.App + '/IncomingWebhook/@@/' + $G.Req) $Sec.Webhook
}

# =============================================================================================
# 2. PATTERNS (README "Rules" 2)
# =============================================================================================
T 'pattern: GUID -> ...0001' SPEC LEAK { $c = New-Ctx; Assert-Exact (Redact $c "TenantId: $($G.Tenant)") "TenantId: $($Ph.G1)" }
T 'pattern: GUIDs numbered, same value same placeholder' SPEC MISC {
    $c = New-Ctx
    Assert-Exact (Redact $c "a $($G.Tenant) b $($G.App) c $($G.Tenant)") "a $($Ph.G1) b $($Ph.G2) c $($Ph.G1)"
}
T 'pattern: GUID uppercase and in braces' SPEC LEAK {
    $c = New-Ctx; $up = $G.App.ToUpperInvariant()
    $out = Redact $c "ObjectId {$up} and $up"
    Assert-NoLeak $out $G.App; Assert-Has $out '00000000-0000-0000-0000-00000000000'
}
T 'pattern: ignore list GUIDs untouched (Graph / SharePoint / ADO app ids)' SPEC FP {
    $c = New-Ctx
    $t = 'resourceAppId 00000003-0000-0000-c000-000000000000, 00000003-0000-0ff1-ce00-000000000000, 499b84ac-1321-427f-aa17-267ca6975798'
    Assert-Exact (Redact $c $t) $t
}
T 'pattern: ignore list GUID in uppercase also untouched' EXPECTATION FP {
    $c = New-Ctx; $t = 'resourceAppId 00000003-0000-0000-C000-000000000000'
    Assert-Exact (Redact $c $t) $t
}
T 'pattern: email -> user1@example.com' SPEC LEAK { $c = New-Ctx; Assert-Exact (Redact $c 'Contact ola.nordmann@fjordtek.no today') 'Contact user1@example.com today' }
T 'pattern: email mixed case is not leaked' SPEC LEAK { $c = New-Ctx; Assert-NoLeak (Redact $c 'From: Ola.Nordmann@Fjordtek.NO') 'nordmann', 'fjordtek' }
T 'pattern: storage account name in blob host' SPEC LEAK {
    $c = New-Ctx
    Assert-Exact (Redact $c 'Uploading to https://stlogs8842.blob.core.windows.net/logs/app.log') 'Uploading to https://storageaccount1.blob.core.windows.net/logs/app.log'
}
T 'pattern: storage account in queue/table/file/dfs hosts' EXPECTATION LEAK {
    $c = New-Ctx
    $out = Redact $c 'q: stq1234.queue.core.windows.net t: stt1234.table.core.windows.net f: stf1234.file.core.windows.net d: stdl1234.dfs.core.windows.net'
    Assert-NoLeak $out 'stq1234', 'stt1234', 'stf1234', 'stdl1234'
}
T 'pattern: storage account in AccountName=' EXPECTATION LEAK {
    $c = New-Ctx; Assert-NoLeak (Redact $c 'DefaultEndpointsProtocol=https;AccountName=stlogs8842;EndpointSuffix=core.windows.net') 'stlogs8842'
}
foreach ($h in @(
        @{ In = 'Site: https://acmecorp.sharepoint.com/sites/HR'; Ex = 'Site: https://resource1.sharepoint.com/sites/HR'; N = 'sharepoint.com' },
        @{ In = 'Tenant acmecorp.onmicrosoft.com'; Ex = 'Tenant resource1.onmicrosoft.com'; N = 'onmicrosoft.com' },
        @{ In = 'Connecting to sql-acme-prod.database.windows.net on port 1433'; Ex = 'Connecting to resource1.database.windows.net on port 1433'; N = 'database.windows.net' },
        @{ In = 'GET https://kv-acme-prod.vault.azure.net/certificates/web'; Ex = 'GET https://resource1.vault.azure.net/certificates/web'; N = 'vault.azure.net' },
        @{ In = 'Deployed to https://func-acme-prod.azurewebsites.net/api/health'; Ex = 'Deployed to https://resource1.azurewebsites.net/api/health'; N = 'azurewebsites.net' },
        @{ In = 'Repo https://dev.azure.com/acmeorg/Intranet/_git/web'; Ex = 'Repo https://dev.azure.com/resource1/Intranet/_git/web'; N = 'dev.azure.com/<org>' }
    )) {
    $hh = $h
    T "pattern: resource host $($hh.N) -> resource1" SPEC LEAK { $c = New-Ctx; Assert-Exact (Redact $c $D.In) $D.Ex } $hh
}
T 'pattern: SharePoint -my and -admin hosts' SPEC LEAK {
    $c = New-Ctx; Assert-NoLeak (Redact $c 'https://acmecorp-my.sharepoint.com/personal/x and https://acmecorp-admin.sharepoint.com/') 'acmecorp'
}
foreach ($suffix in 'servicebus.windows.net', 'azure-api.net', 'azurecr.io', 'redis.cache.windows.net', 'documents.azure.com', 'azurestaticapps.net', 'openai.azure.com', 'scm.azurewebsites.net', 'visualstudio.com', 'crm4.dynamics.com', 'azurefd.net', 'postgres.database.azure.com') {
    $s = $suffix
    T "pattern: resource host '…' family: .$s" EXPECTATION LEAK { $c = New-Ctx; Assert-NoLeak (Redact $c "Endpoint: https://acmeprod42.$D/x") 'acmeprod42' } $s
}
foreach ($fq in @(@{ H = 'dc01.acme.local' }, @{ H = 'nas.acme.lan' }, @{ H = 'srv7.acme.corp' }, @{ H = 'build.acme.internal' }, @{ H = 'dc02.acme.ad' })) {
    $f = $fq
    T "pattern: internal FQDN $($f.H) -> host1.internal" SPEC LEAK { $c = New-Ctx; Assert-Exact (Redact $c "Ping $($D.H) failed") 'Ping host1.internal failed' } $f
}
T 'pattern: internal FQDN in uppercase' EXPECTATION LEAK { $c = New-Ctx; Assert-NoLeak (Redact $c 'Resolve DC01.ACME.LOCAL') 'DC01', 'ACME' }
T 'pattern: internal FQDN in Kerberos SPN / UNC' EXPECTATION LEAK {
    $c = New-Ctx; Assert-NoLeak (Redact $c 'SPN HTTP/web01.acme.local registered; share \\fs01.acme.local\data') 'web01', 'fs01', 'acme'
}
foreach ($hc in @(
        @{ In = 'hostname: WKS0042'; Ex = 'hostname: host1' },
        @{ In = 'Computer name: LAPTOP-7XK2P'; Ex = 'Computer name: host1' },
        @{ In = 'server: SQLPROD01'; Ex = 'server: host1' },
        @{ In = 'host=pgsql01'; Ex = 'host=host1' }
    )) {
    $x = $hc
    T "pattern: host after keyword '$($x.In)'" SPEC LEAK { $c = New-Ctx; Assert-Exact (Redact $c $D.In) $D.Ex } $x
}
T 'pattern: host= value in ignore (localhost) untouched' SPEC FP { $c = New-Ctx; Assert-Exact (Redact $c 'Host=localhost;Port=5432') 'Host=localhost;Port=5432' }
T 'leak: host in "Data Source=" (SQL)' EXPECTATION LEAK { $c = New-Ctx; Assert-NoLeak (Redact $c 'Data Source=SQLPROD01;Initial Catalog=app;Integrated Security=True') 'SQLPROD01' }
T 'leak: host in PowerShell Format-List "ComputerName  : X"' EXPECTATION LEAK { $c = New-Ctx; Assert-NoLeak (Redact $c (L 'ComputerName  : WKS-OSL-042' 'Status        : Running')) 'WKS-OSL-042' }
T 'leak: host in JSON "server": "X"' EXPECTATION LEAK { $c = New-Ctx; Assert-NoLeak (Redact $c '{"server": "SQLPROD01", "database": "app"}') 'SQLPROD01' }
T 'leak: host after MachineName:' EXPECTATION LEAK { $c = New-Ctx; Assert-NoLeak (Redact $c 'MachineName: WKS-OSL-042') 'WKS-OSL-042' }
T 'leak: host in UNC path \\FILESRV01\share' EXPECTATION LEAK { $c = New-Ctx; Assert-NoLeak (Redact $c 'Copy failed: \\FILESRV01\share\a.txt') 'FILESRV01' }

foreach ($uc in @(
        @{ In = 'C:\Users\jdoe\AppData\Local\Temp\x.log'; Ex = 'C:\Users\winuser1\AppData\Local\Temp\x.log' },
        @{ In = 'cd /home/jdoe/src'; Ex = 'cd /home/winuser1/src' },
        @{ In = 'open /Users/jdoe/Library/Logs'; Ex = 'open /Users/winuser1/Library/Logs' },
        @{ In = 'ACME\jdoe logged on'; Ex = 'ACME\winuser1 logged on' }
    )) {
    $u = $uc
    T "pattern: user folder/DOMAIN\user '$($u.In)'" SPEC LEAK { $c = New-Ctx; Assert-Exact (Redact $c $D.In) $D.Ex } $u
}
T 'pattern: C:\Users\Public and \Default untouched' SPEC FP {
    $c = New-Ctx; $t = 'C:\Users\Public\Documents and C:\Users\Default\NTUSER.DAT'
    Assert-Exact (Redact $c $t) $t
}
T 'leak: JSON-escaped user path C:\\Users\\jdoe' EXPECTATION LEAK { $c = New-Ctx; Assert-NoLeak (Redact $c '{"path":"C:\\Users\\jdoe\\AppData\\x.json"}') 'jdoe' }
T 'leak: forward-slash user path C:/Users/jdoe' EXPECTATION LEAK { $c = New-Ctx; Assert-NoLeak (Redact $c 'file:///C:/Users/jdoe/Downloads/a.pdf') 'jdoe' }
T 'leak: lowercase c:\users\jdoe' EXPECTATION LEAK { $c = New-Ctx; Assert-NoLeak (Redact $c 'c:\users\jdoe\desktop') 'jdoe' }

T 'pattern: own COMPUTERNAME/USERNAME whole word' SPEC LEAK {
    $c = New-Ctx; Assert-Exact (Redact $c 'Build on WS-TESTBOX77 by kjetilh') 'Build on machine1 by winuser1'
}
T 'pattern: own USERNAME taken from environment' SPEC LEAK {
    $c = New-Ctx; Assert-Exact (Redact $c 'Logged in as mariell' -EnvVars @{ USERNAME = 'mariell'; USER = 'mariell' }) 'Logged in as winuser1'
}
T 'pattern: own USERNAME is whole-word only' SPEC FP { $c = New-Ctx; Assert-Exact (Redact $c 'Owner kjetilhansen') 'Owner kjetilhansen' }
T 'pattern: own USERNAME in path and free text share one placeholder' SPEC MISC {
    $c = New-Ctx; Assert-Exact (Redact $c 'C:\Users\kjetilh\x and kjetilh') 'C:\Users\winuser1\x and winuser1'
}
T 'pattern: own COMPUTERNAME in lowercase' EXPECTATION LEAK { $c = New-Ctx; Assert-NoLeak (Redact $c 'ssh ws-testbox77') 'testbox77' }

T 'pattern: thumbprint after Thumbprint:' SPEC LEAK { $c = New-Ctx; Assert-Exact (Redact $c "Thumbprint: $Thumb") 'Thumbprint: THUMBPRINT01' }
T 'pattern: thumbprint after x5t' SPEC LEAK { $c = New-Ctx; Assert-Exact (Redact $c "x5t: $Thumb") 'x5t: THUMBPRINT01' }
T 'pattern: thumbprint after -Thumbprint parameter' SPEC LEAK { $c = New-Ctx; Assert-NoLeak (Redact $c "Connect-PnPOnline -Url https://x.sharepoint.com -Thumbprint $Thumb2") $Thumb2 }
T 'pattern: bare 40-hex git hash kept' SPEC FP { $c = New-Ctx; $t = "commit $GitSha (HEAD -> main)"; Assert-Exact (Redact $c $t) $t }

T 'pattern: IPv4 -> 192.0.2.1' SPEC LEAK { $c = New-Ctx; Assert-Exact (Redact $c 'Client 10.20.30.40 connected') 'Client 192.0.2.1 connected' }
T 'pattern: IPv4 with port and CIDR' SPEC LEAK { $c = New-Ctx; Assert-NoLeak (Redact $c 'Allow 10.42.7.9:443 from 172.16.40.0/22') '10.42.7.9', '172.16.40.0' }
T 'pattern: ignore list 127.0.0.1, 0.0.0.0, localhost untouched' SPEC FP {
    $c = New-Ctx; $t = 'Listening on 0.0.0.0:7071, 127.0.0.1 and localhost'; Assert-Exact (Redact $c $t) $t
}
T 'pattern: 300 distinct IPs -> valid, unique, documentation-range IPs' SPEC LEAK {
    $c = New-Ctx
    $ips = foreach ($i in 0..299) { '10.{0}.{1}.{2}' -f (1 + [int]($i / 200)), ($i % 200), (7 + $i % 13) }
    $text = $ips -join "`n"
    $out = Redact $c $text
    $lines = $out -split "`n"
    Assert-True ($lines.Count -eq 300) "expected 300 lines, got $($lines.Count)"
    $docRanges = '^(192\.0\.2|198\.51\.100|203\.0\.113)\.'
    foreach ($l in $lines) {
        $ok = $l -match '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$' -and (1..4 | ForEach-Object { [int]$Matches[$_] -le 255 }) -notcontains $false
        Assert-True $ok "not a valid IPv4: '$l'"
        Assert-True ($l -match $docRanges) "not in documentation range: '$l'"
    }
    Assert-True (($lines | Sort-Object -Unique).Count -eq 300) 'placeholders are not unique'
}

T 'pattern: custom patterns from example mapping (SERVER{n}, TICKET-{n})' SPEC LEAK {
    $c = New-Ctx; Assert-Exact (Redact $c 'Ticket FJT-1234 on SRV-APP01') 'Ticket TICKET-1 on SERVER1'
}
T 'pattern: custom pattern with named group v replaces only the group' SPEC MISC {
    $c = New-Ctx (New-Mapping -Patterns @(@{ name = 'ref'; regex = 'ref=(?<v>\d+)'; replace = 'REF{n}' }))
    Assert-Exact (Redact $c 'ref=4711 done') 'ref=REF1 done'
}

# =============================================================================================
# 3. LITERALS (README "Rules" 3)
# =============================================================================================
T 'literal: substring inside longer words' SPEC LEAK {
    $c = New-Ctx; Assert-Exact (Redact $c 'Deploying func-fjordtek-prod to rg-fjordtek-prod (fjordtek.no)') 'Deploying func-contoso-prod to rg-contoso-prod (contoso.no)'
}
T 'literal: case-insensitive (FJORDTEK-PC042, FjordTek)' SPEC LEAK {
    $c = New-Ctx; $out = Redact $c 'Joined FJORDTEK-PC042 to FjordTek domain'
    Assert-NoLeak $out 'fjordtek'; Assert-Has $out 'contoso' -CI; Assert-Has $out '-PC042'
}
T 'literal: longest first (Fjordtek AS -> Contoso Ltd)' SPEC MISC { $c = New-Ctx; Assert-Exact (Redact $c 'Customer: Fjordtek AS signed') 'Customer: Contoso Ltd signed' }
T 'literal: wholeWord FJT only as whole word' SPEC FP { $c = New-Ctx; Assert-Exact (Redact $c 'FJT team, FJTX and NFJT') 'CTS team, FJTX and NFJT' }
T 'literal: wholeWord FJT next to hyphen/dot' EXPECTATION LEAK { $c = New-Ctx; Assert-NoLeak (Redact $c 'Agent FJT-BUILD-01 in FJT.Intranet') 'FJT' }
T 'literal: person name Ola Nordmann -> Person One' SPEC LEAK { $c = New-Ctx; Assert-Exact (Redact $c 'Owner: Ola Nordmann') 'Owner: Person One' }
T 'literal: special regex chars in find are literal' EXPECTATION MISC {
    $c = New-Ctx (New-Mapping -Replacements @(@{ find = 'A+B (Norge)'; replace = 'Partner Co' }))
    Assert-Exact (Redact $c 'Vendor A+B (Norge) and AAB Norge') 'Vendor Partner Co and AAB Norge'
}
T 'literal: Norwegian letters in find value' EXPECTATION LEAK {
    $c = New-Ctx (New-Mapping -Replacements @(@{ find = 'Kåre Ødegård'; replace = 'Person Two' }))
    $out = Redact $c 'Approved by Kåre Ødegård and KÅRE ØDEGÅRD'
    Assert-NoLeak $out 'Ødegård'
}
T 'literal: resource ID with customer name and subscription GUID' SPEC LEAK {
    $c = New-Ctx
    $out = Redact $c "/subscriptions/$($G.Sub)/resourceGroups/rg-fjordtek-prod/providers/Microsoft.Web/sites/func-fjordtek-prod"
    Assert-NoLeak $out 'fjordtek', $G.Sub
}
T 'literal: chained mapping (fjordtek->contoso, contoso->fabrikam) is not applied twice' EXPECTATION MISC {
    $c = New-Ctx (New-Mapping -Replacements @(@{ find = 'fjordtek'; replace = 'contoso' }, @{ find = 'contoso'; replace = 'fabrikam' }))
    Assert-Exact (Redact $c 'fjordtek partners with contoso') 'contoso partners with fabrikam'
}
T 'literal: two values may share a placeholder (case-insensitively)' SPEC MAPPING {
    $c = New-Ctx (New-Mapping -Replacements @(@{ find = 'fjordtek'; replace = 'contoso' }, @{ find = 'nordlys'; replace = 'Contoso' }))
    Assert-Exact (Redact $c 'fjordtek and nordlys') 'contoso and Contoso'
}

# =============================================================================================
# 4. LEAK HUNTING (realistic forms the spec may not anticipate)
# =============================================================================================
T 'leak: Entra guest UPN ola.nordmann_fjordtek.no#EXT#@...' EXPECTATION LEAK {
    $c = New-Ctx; Assert-NoLeak (Redact $c 'UserPrincipalName: ola.nordmann_fjordtek.no#EXT#@partnerco.onmicrosoft.com') 'nordmann', 'fjordtek'
}
T 'leak: URL-encoded email in login_hint' EXPECTATION LEAK {
    $c = New-Ctx; Assert-NoLeak (Redact $c 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=x&login_hint=ola.nordmann%40fjordtek.no') 'nordmann', 'fjordtek'
}
T 'leak: OneDrive personal site URL ola_nordmann_fjordtek_no' EXPECTATION LEAK {
    $c = New-Ctx; Assert-NoLeak (Redact $c 'https://fjordtek-my.sharepoint.com/personal/ola_nordmann_fjordtek_no/Documents/plan.xlsx') 'nordmann', 'fjordtek'
}
T 'leak: SharePoint claims login i:0#.f|membership|upn' SPEC LEAK {
    $c = New-Ctx; Assert-NoLeak (Redact $c 'LoginName: i:0#.f|membership|ola.nordmann@fjordtek.no') 'nordmann', 'fjordtek'
}
T 'leak: person name reversed "Nordmann, Ola" (AD displayName)' EXPECTATION LEAK {
    $c = New-Ctx; Assert-NoLeak (Redact $c 'displayName: Nordmann, Ola') 'Nordmann'
}
T 'leak: person name with double space / line break' EXPECTATION LEAK {
    $c = New-Ctx; Assert-NoLeak (Redact $c (L 'Owner: Ola  Nordmann' 'Reviewer: Ola' 'Nordmann')) 'Nordmann'
}
T 'leak: person login ola.nordmann without domain' EXPECTATION LEAK {
    $c = New-Ctx; Assert-NoLeak (Redact $c 'sAMAccountName: ola.nordmann') 'nordmann'
}
T 'leak: IDN email with Norwegian letters' EXPECTATION LEAK {
    $c = New-Ctx; Assert-NoLeak (Redact $c 'Mail sent to kåre.ødegård@fjordtek.no') 'ødegård', 'kåre', 'fjordtek'
}
T 'leak: email with plus-addressing' SPEC LEAK { $c = New-Ctx; Assert-NoLeak (Redact $c 'Reply-To: ola+alerts@fjordtek.no') 'ola+alerts', 'fjordtek' }
T 'leak: customer abbreviation inside agent machine name (fjtbuild01vm)' EXPECTATION LEAK {
    $c = New-Ctx; Assert-NoLeak (Redact $c "Agent machine name: 'fjtbuild01vm'") 'fjtbuild01vm'
}
T 'leak: tenant domain in login.microsoftonline.com path' SPEC LEAK {
    $c = New-Ctx; Assert-NoLeak (Redact $c 'POST https://login.microsoftonline.com/acmecorp.onmicrosoft.com/oauth2/v2.0/token') 'acmecorp'
}
T 'leak: ADO org in git clone URL with user@ prefix' SPEC LEAK {
    $c = New-Ctx; Assert-NoLeak (Redact $c 'git clone https://acmeorg@dev.azure.com/acmeorg/Intranet/_git/web') 'acmeorg'
}
T 'leak: OneDrive folder name with customer company name' SPEC LEAK {
    $c = New-Ctx; Assert-NoLeak (Redact $c 'C:\Users\ola.nordmann\OneDrive - Fjordtek AS\Docs') 'nordmann', 'fjordtek'
}

# =============================================================================================
# 5. FALSE POSITIVES (useful info destroyed)
# =============================================================================================
T 'fp: timestamps, versions, durations, HTTP status untouched' EXPECTATION FP {
    $c = New-Ctx
    $t = "2026-10-11T08:38:12.3456789Z [Information] Executed 'Functions.SyncUsers' (Succeeded, Duration=1532ms) host v4.1037.0.23 PnP.PowerShell 2.12.0 build 20261011.3 HTTP 404 port 443"
    Assert-Exact (Redact $c $t) $t
}
T 'fp: AADSTS7000215 message text kept' EXPECTATION FP {
    $c = New-Ctx
    $t = 'AADSTS7000215: Invalid client secret provided. Ensure the secret being sent in the request is the client secret value, not the client secret ID, for a secret added to app.'
    Assert-Exact (Redact $c $t) $t
}
T 'fp: plain prose with Token/Secret/Password words kept' EXPECTATION FP {
    $c = New-Ctx; $t = (L 'Token expired. Please sign in again.' 'Secret rotation completed successfully.' 'Password reset required for 3 users.')
    Assert-Exact (Redact $c $t) $t
}
T 'fp: .NET assembly PublicKeyToken kept' EXPECTATION FP {
    $c = New-Ctx; $t = "Could not load file or assembly 'Azure.Identity, Culture=neutral, PublicKeyToken=92742159e12e44c8'."
    Assert-Exact (Redact $c $t) $t
}
T 'fp: 4-part assembly version that looks like an IP kept' EXPECTATION FP {
    $c = New-Ctx; $t = "Could not load 'Microsoft.Identity.Client, Version=4.61.3.0' (FileVersion 6.2.1.0)"
    Assert-Exact (Redact $c $t) $t
}
T 'fp: .NET stack trace with .Internal. namespaces kept' EXPECTATION FP {
    $c = New-Ctx
    $t = (L '   at Microsoft.Azure.WebJobs.Script.Workers.Rpc.Internal.GrpcWorkerChannel.StartWorkerProcessAsync()' '   at Microsoft.AspNetCore.Server.Kestrel.Core.Internal.Http.HttpProtocol.ProcessRequestsAsync()')
    Assert-Exact (Redact $c $t) $t
}
T 'fp: Windows system paths and registry keys kept (not DOMAIN\user)' EXPECTATION FP {
    $c = New-Ctx; $t = 'C:\Windows\System32\drivers\etc\hosts and HKLM\SOFTWARE\Microsoft\Windows'
    Assert-Exact (Redact $c $t) $t
}
T 'fp: JSON \n escape not taken as DOMAIN\user' EXPECTATION FP {
    $c = New-Ctx; $t = '{"message":"Upload failed\nRetrying in 5s"}'
    Assert-Exact (Redact $c $t) $t
}
T 'fp: NT AUTHORITY\SYSTEM and BUILTIN\Administrators kept' EXPECTATION FP {
    $c = New-Ctx; $t = 'Run as NT AUTHORITY\SYSTEM; member of BUILTIN\Administrators'
    Assert-Exact (Redact $c $t) $t
}
T 'fp: HTTP "Server: Microsoft-IIS/10.0" / "Server: Kestrel" header kept' EXPECTATION FP {
    $c = New-Ctx; $t = (L 'Server: Microsoft-IIS/10.0' 'Server: Kestrel')
    Assert-Exact (Redact $c $t) $t
}
T 'fp: well-known Microsoft endpoints kept' EXPECTATION FP {
    $c = New-Ctx
    $t = (L 'POST https://login.microsoftonline.com/common/oauth2/v2.0/token' 'GET https://graph.microsoft.com/v1.0/users' 'scope=https://database.windows.net/.default https://vault.azure.net/.default https://storage.azure.com/.default' 'PUT https://management.azure.com/subscriptions?api-version=2022-12-01')
    Assert-Exact (Redact $c $t) $t
}
T 'fp: npm package@version (SPFx) not taken as email' EXPECTATION FP {
    $c = New-Ctx; $t = (L '+ @microsoft/sp-core-library@1.20.0' '+ @pnp/sp@4.5.0')
    Assert-Exact (Redact $c $t) $t
}
T 'fp: git@github.com SSH remote kept' EXPECTATION FP {
    $c = New-Ctx; $t = 'remote: git@github.com:pnp/sp-dev-fx-webparts.git'
    Assert-Exact (Redact $c $t) $t
}
T 'fp: token_type Bearer does not eat following fields' EXPECTATION FP {
    $c = New-Ctx; Assert-Has (Redact $c '{"token_type":"Bearer","expires_in":3599,"ext_expires_in":3599}') '"expires_in":3599', '"ext_expires_in":3599'
}
T 'fp: Unicode (Norwegian) text unchanged' EXPECTATION FP {
    $c = New-Ctx; $t = 'Prosjektrom for økonomi – årsoppgjør ÆØÅ'
    Assert-Exact (Redact $c $t) $t
}
T 'fp: re-running on already anonymised text changes nothing (idempotent)' EXPECTATION FP {
    $c = New-Ctx
    $out1 = Redact $c "User ola.nordmann@fjordtek.no from 10.1.2.3 tenant $($G.Tenant) on dc01.acme.local"
    Assert-Exact (Redact $c $out1) $out1
}

# =============================================================================================
# 6. STATELESS
# =============================================================================================
T 'stateless: no files written next to mapping.json' SPEC MISC {
    $c = New-Ctx -SubDir 'cust'
    [void](Redact $c "id $($G.App) mail ola.nordmann@fjordtek.no ip 10.1.2.3")
    $files = @(Get-ChildItem -LiteralPath $c.MapDir -Name)
    Assert-True ($files.Count -eq 1 -and $files[0] -eq 'mapping.json') "unexpected files: $($files -join ', ')"
}
T 'stateless: same input twice gives identical output' SPEC MISC {
    $c = New-Ctx; $t = "User ola.nordmann@fjordtek.no tenant $($G.Tenant) ip 10.1.2.3 host dc01.acme.local"
    Assert-Exact (Redact $c $t) (Redact $c $t)
}
T 'stateless: numbering starts at 1 on every run' SPEC MISC {
    $c = New-Ctx
    Assert-Exact (Redact $c "first $($G.App)") "first $($Ph.G1)"
    Assert-Exact (Redact $c "second $($G.Tenant) then $($G.App)") "second $($Ph.G1) then $($Ph.G2)"
}
T 'stateless: placeholders already in the input are kept and not reused' SPEC MISC {
    $c = New-Ctx
    Assert-Exact (Redact $c "known $($Ph.G1), user1@example.com, 192.0.2.1, host1.internal, SERVER1; new $($G.App), a@b.no, 10.1.1.1, dc01.acme.local, SRV-X") `
        "known $($Ph.G1), user1@example.com, 192.0.2.1, host1.internal, SERVER1; new $($Ph.G2), user2@example.com, 192.0.2.2, host2.internal, SERVER2"
}

# ---- realistic logs ------------------------------------------------------------------------
$LogEntra = (@'
PS> Connect-MgGraph -TenantId {{TEN}} -ClientId {{APP}}
Get-MgUser_Get: Resource 'ola.nordmann@fjordtek.no' does not exist or one of its queried reference-property objects are not present.
Status: 404 (NotFound)
ErrorCode: Request_ResourceNotFound
Date: 2026-10-11T08:38:12
Headers:
Transfer-Encoding             : chunked
request-id                    : {{REQ}}
client-request-id             : {{REQ2}}
x-ms-ags-diagnostic           : {"ServerInfo":{"DataCenter":"North Europe","Slice":"E","Ring":"4","ScaleUnit":"000","RoleInstance":"DB1PEPF00001A2B"}}
AADSTS700016: Application with identifier '{{APP}}' was not found in the directory 'fjordtek.onmicrosoft.com'.
Trace ID: {{INV}}
'@).Replace('{{TEN}}', $G.Tenant).Replace('{{APP}}', $G.App).Replace('{{REQ}}', $G.Req).Replace('{{REQ2}}', $G.Req2).Replace('{{INV}}', $G.Inv)

$LogFunc = (@'
2026-10-11T08:38:00.123 [Information] Executing 'Functions.SyncUsers' (Reason='Timer fired at 2026-10-11T08:38:00.1220000+00:00', Id={{INV}})
2026-10-11T08:38:00.456 [Information] Connecting to https://fjordtek.sharepoint.com/sites/HR as {{APP}}
2026-10-11T08:38:00.789 [Warning] Retrying blob upload to https://stfjordtekdata.blob.core.windows.net/export (attempt 2)
2026-10-11T08:38:01.002 [Error] Executed 'Functions.SyncUsers' (Failed, Id={{INV}}, Duration=879ms)
System.Net.Http.HttpRequestException: No such host is known. (kv-fjordtek-prod.vault.azure.net:443)
   at System.Net.Http.HttpConnectionPool.ConnectToTcpHostAsync(String host, Int32 port, HttpRequestMessage initialRequest, Boolean async, CancellationToken cancellationToken)
   at Acme.Sync.Func.SyncUsers.Run(TimerInfo timer) in C:\Users\ola.nordmann\source\repos\Acme.Sync.Func\SyncUsers.cs:line 42
Outbound IP 10.0.4.17 -> 10.0.8.5, DNS 10.0.0.4, resolver dc01.fjordtek.local
'@).Replace('{{INV}}', $G.Inv).Replace('{{APP}}', $G.App)

$LogPnP = (@'
PS C:\Users\ola.nordmann> Connect-PnPOnline -Url https://fjordtek.sharepoint.com/sites/Prosjekt -ClientId {{APP}} -Tenant fjordtek.onmicrosoft.com -Thumbprint {{THUMB}}
PS C:\Users\ola.nordmann> Get-PnPSiteCollectionAdmin

Title        Email                     LoginName
-----        -----                     ---------
Ola Nordmann ola.nordmann@fjordtek.no  i:0#.f|membership|ola.nordmann@fjordtek.no
Kari Admin   kari.admin@fjordtek.no    i:0#.f|membership|kari.admin@fjordtek.no

PS C:\Users\ola.nordmann> Invoke-PnPSiteTemplate -Path .\template.xml
WARNING: Site https://fjordtek-admin.sharepoint.com is NoScript, skipping custom actions.
'@).Replace('{{APP}}', $G.App).Replace('{{THUMB}}', $Thumb)

$LogAdo = (@'
##[section]Starting: Deploy Function App
Pool: Azure Pipelines
Agent name: 'FJT-BUILD-01'
Current agent version: '4.248.0'
Operating System: Ubuntu 22.04.5 LTS
Downloading task: AzureFunctionApp (2.246.3)
Repository: https://dev.azure.com/fjordtekorg/Intranett/_git/intranett-spfx
Commit: {{SHA}}
Requested for: Ola Nordmann (ola.nordmann@fjordtek.no)
##[error]Error: Failed to deploy web package to App Service. Conflict (CODE: 409)
Resource: /subscriptions/{{SUB}}/resourceGroups/rg-fjordtek-prod/providers/Microsoft.Web/sites/func-fjordtek-prod
Ticket FJT-2211 raised on SRV-BUILD07
##[section]Finishing: Deploy Function App
'@).Replace('{{SHA}}', $GitSha).Replace('{{SUB}}', $G.Sub)

$LogHosts = (@'
hostname: WKS0042
Resolved dc01.fjordtek.local to 10.10.1.5
Computer name: LAPTOP-7XK2P
User FJORDTEK\mhansen opened C:\Users\mhansen\Desktop\run.ps1
Build on WS-TESTBOX77 by kjetilh in C:\Users\kjetilh\src
'@)

$Logs = @(
    @{ N = 'Entra/Graph error'; T = $LogEntra; F = @('fjordtek', 'nordmann', $G.Tenant, $G.App, $G.Req, $G.Inv) },
    @{ N = 'Azure Functions log'; T = $LogFunc; F = @('fjordtek', 'nordmann', $G.App, $G.Inv, '10.0.4.17', '10.0.8.5', 'stfjordtekdata') },
    @{ N = 'PnP.PowerShell output'; T = $LogPnP; F = @('fjordtek', 'nordmann', 'kari.admin', $G.App, $Thumb) },
    @{ N = 'ADO pipeline log'; T = $LogAdo; F = @('fjordtek', 'nordmann', $G.Sub, 'FJT-2211', 'SRV-BUILD07', "'FJT-") },
    @{ N = 'hosts/users/own machine mix (host1 vs host1.internal, winuser)'; T = $LogHosts; F = @('WKS0042', 'fjordtek', 'mhansen', 'LAPTOP-7XK2P', 'TESTBOX77', 'kjetilh', '10.10.1.5') }
)
foreach ($lg in $Logs) {
    $x = $lg
    T "realistic: $($x.N)" SPEC LEAK {
        $c = New-Ctx
        $anon = Redact $c $D.T
        Assert-NoLeak $anon $D.F
        Assert-Exact (Redact $c $anon) $anon
    } $x
}
T 'realistic: connection strings (secrets become <redacted:…>, rest kept)' SPEC LEAK {
    $c = New-Ctx
    $t = (@'
[2026-10-11 08:40:01] Loading settings for func-fjordtek-prod
AzureWebJobsStorage=DefaultEndpointsProtocol=https;AccountName=stfjordtekprod;AccountKey={{STOR}};EndpointSuffix=core.windows.net
SqlConnection=Server=tcp:sql-fjordtek-prod.database.windows.net,1433;Initial Catalog=sqldb-workflow;User ID=sqladmin;Password={{SQLPW}};Encrypt=True;Connection Timeout=30;
APPLICATIONINSIGHTS_CONNECTION_STRING=InstrumentationKey={{AIKEY}};IngestionEndpoint=https://norwayeast-0.in.applicationinsights.azure.com/
BlobSas=https://stfjordtekdata.blob.core.windows.net/export/users.csv?sv=2022-11-02&ss=b&srt=o&sp=r&se=2026-12-31T23:59:59Z&spr=https&sig={{SIG}}
[2026-10-11 08:40:02] Settings loaded (4 values)
'@).Replace('{{STOR}}', $Sec.StorKey).Replace('{{SQLPW}}', $Sec.SqlPw).Replace('{{AIKEY}}', $G.AiKey).Replace('{{SIG}}', $Sec.Sig)
    $anon = Redact $c $t
    Assert-NoLeak $anon ((Hide $Sec.StorKey) + (Hide $Sec.SqlPw) + (Hide $Sec.Sig) + @('fjordtek', $G.AiKey))
    Assert-Has $anon 'Encrypt=True;Connection Timeout=30;', 'EndpointSuffix=core.windows.net', 'Settings loaded (4 values)'
}

# =============================================================================================
# 7. MAPPING VALIDATION / CLI
# =============================================================================================
T 'mapping: empty replace rejected' SPEC MAPPING {
    $c = New-Ctx (New-Mapping -Replacements @(@{ find = 'fjordtek'; replace = '' }))
    $r = Invoke-Tool -Ctx $c -Text 'fjordtek'
    Assert-True (Test-HasError $r) "expected an error, got exit $($r.Code), stdout '$($r.Out)'"
    Assert-NoLeak $r.Out 'fjordtek'
}
T 'mapping: empty find skipped with warning, other rules still applied' SPEC MAPPING {
    $c = New-Ctx (New-Mapping -Replacements @(@{ find = ''; replace = 'blank' }, @{ find = 'fjordtek'; replace = 'contoso' }))
    $r = Invoke-Tool -Ctx $c -Text 'fjordtek site'
    Assert-True ($r.Code -eq 0) "exit $($r.Code): $($r.Err)"
    Assert-Exact $r.Out 'contoso site'
    Assert-True ($r.Err.Length -gt 0) 'no warning on stderr / warning stream'
}
T 'mapping: relative -MappingPath resolved from current folder' SPEC MAPPING {
    $c = New-Ctx
    $r = Invoke-Tool -Ctx $c -Text "fjordtek $($G.App)" -MapArg 'mapping.json' -WorkDir $c.Dir
    Assert-True ($r.Code -eq 0) "exit $($r.Code): $($r.Err)"
    Assert-Exact $r.Out "contoso $($Ph.G1)"
}
T 'mapping: relative -MappingPath in subfolder' SPEC MAPPING {
    $c = New-Ctx -SubDir 'cust'
    $r = Invoke-Tool -Ctx $c -Text 'fjordtek' -MapArg (Join-Path 'cust' 'mapping.json') -WorkDir $c.Dir
    Assert-True ($r.Code -eq 0) "exit $($r.Code): $($r.Err)"
    Assert-Exact $r.Out 'contoso'
}
T 'mapping: REDACT_MAPPING env var used when -MappingPath omitted' SPEC MAPPING {
    $c = New-Ctx
    $r = Invoke-Tool -Ctx $c -Text 'fjordtek' -NoMap -EnvVars @{ REDACT_MAPPING = $c.Map }
    Assert-True ($r.Code -eq 0) "exit $($r.Code): $($r.Err)"
    Assert-Exact $r.Out 'contoso'
}
T 'mapping: missing mapping file fails closed' EXPECTATION MAPPING {
    $c = New-Ctx
    $r = Invoke-Tool -Ctx $c -Text 'ola.nordmann@fjordtek.no' -MapArg (Join-Path $c.Dir 'nope.json')
    Assert-True (Test-HasError $r) "expected an error, got exit $($r.Code), stdout '$($r.Out)'"
    Assert-NoLeak $r.Out 'fjordtek', 'nordmann'
}
T 'mapping: invalid JSON fails closed' EXPECTATION MAPPING {
    $c = New-Ctx '{ "replacements": [ { "find": "fjordtek", "replace": "contoso" } '
    $r = Invoke-Tool -Ctx $c -Text 'fjordtek'
    Assert-True (Test-HasError $r) "expected an error, got exit $($r.Code), stdout '$($r.Out)'"
    Assert-NoLeak $r.Out 'fjordtek'
}
T 'cli: empty input file' EXPECTATION MISC {
    $c = New-Ctx; $r = Invoke-Tool -Ctx $c -Text ''
    Assert-True ($r.Code -eq 0) "exit $($r.Code): $($r.Err)"
    Assert-Exact $r.Out ''
}
T 'cli: -Quiet keeps stderr clean on a normal run' SPEC MISC {
    $c = New-Ctx; $r = Invoke-Tool -Ctx $c -Text 'fjordtek'
    Assert-True ($r.Code -eq 0 -and $r.Err.Length -eq 0) "stderr not empty: $($r.Err)"
}
T 'perf: ~500 KB log processed in reasonable time (README: ~0.5 MB/s)' SPEC MISC {
    $c = New-Ctx
    $line = "2026-10-11T08:38:00Z [Information] user ola.nordmann@fjordtek.no tenant $($G.Tenant) from 10.1.2.3 via https://fjordtek.sharepoint.com/sites/HR ok"
    $t = (1..3500 | ForEach-Object { $line }) -join "`n"
    $r = Invoke-Tool -Ctx $c -Text $t
    Assert-True ($r.Code -eq 0) "exit $($r.Code)"
    Assert-NoLeak $r.Out 'fjordtek', 'nordmann'
    Assert-True ($r.Ms -lt 15000) "took $($r.Ms) ms for $([int]($t.Length/1024)) KB"
}

# =============================================================================================
# Run
# =============================================================================================
$results = [Collections.Generic.List[object]]::new()
$selected = @($Tests | Where-Object Name -Like $Filter)
Write-Host ("Running {0} tests against {1}`nTemp: {2}`n" -f $selected.Count, $ScriptPath, $Root)
foreach ($t in $selected) {
    $script:Trace.Clear()
    $msg = $null
    $script:D = $t.Data
    try { & $t.Body | Out-Null } catch { $msg = $_.Exception.Message }
    $ok = $null -eq $msg
    $results.Add([pscustomobject]@{ Name = $t.Name; Cat = $t.Cat; Kind = $t.Kind; Pass = $ok; Msg = $msg })
    if ($ok) { Write-Host ("PASS [{0,-11}] [{1,-9}] {2}" -f $t.Cat, $t.Kind, $t.Name) -ForegroundColor Green }
    else {
        Write-Host ("FAIL [{0,-11}] [{1,-9}] {2}" -f $t.Cat, $t.Kind, $t.Name) -ForegroundColor Red
        Write-Host ('     ' + ($msg -replace "`n", "`n     "))
        $tr = ($script:Trace -join "`n")
        if ($tr.Length -gt 2500) { $tr = $tr.Substring(0, 2500) + "`n     ...(truncated)" }
        Write-Host ('     ' + ($tr -replace "`n", "`n     ")) -ForegroundColor DarkGray
    }
}

Write-Host "`n==================== SUMMARY ===================="
foreach ($g in ($results | Group-Object Cat | Sort-Object Name)) {
    $p = @($g.Group | Where-Object Pass).Count
    Write-Host ("{0,-11} {1,3} tests  {2,3} pass  {3,3} fail" -f $g.Name, $g.Count, $p, ($g.Count - $p))
}
$fails = @($results | Where-Object { -not $_.Pass })
Write-Host ("TOTAL       {0,3} tests  {1,3} pass  {2,3} fail" -f $results.Count, ($results.Count - $fails.Count), $fails.Count)
if ($fails) {
    Write-Host "`nFailed:"
    foreach ($f in $fails | Sort-Object { @{ LEAK = 0; MAPPING = 1; FP = 2; MISC = 3 }[$_.Kind] }) {
        Write-Host ("  [{0}] [{1}] {2}" -f $f.Kind, $f.Cat, $f.Name)
    }
}
if (-not $KeepTemp) { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
exit ($fails.Count -gt 0 ? 1 : 0)
