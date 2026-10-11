<#
.SYNOPSIS
    Self-test for Redact.ps1. Runs in a temp folder; never touches your mapping.json.
.EXAMPLE
    .\Tests\Test-Redact.ps1
#>
[CmdletBinding()] param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$script = Join-Path $root 'Redact.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("redact-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
Copy-Item (Join-Path $root 'mapping.example.json') (Join-Path $tmp 'mapping.json')
$map = Join-Path $tmp 'mapping.json'
$script:fail = 0; $script:pass = 0

function Invoke-Redact([string]$text, [switch]$Restore, [string]$Mapping = $map) {
    $in = Join-Path $tmp 'in.txt'
    [IO.File]::WriteAllText($in, $text)
    $out = & $script -Path $in -NoClipboard -Quiet -MappingPath $Mapping -Restore:$Restore 2>$null
    ($out -join "`n").TrimEnd()
}

function Assert([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Host "  PASS  $name" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  FAIL  $name  $detail" -ForegroundColor Red }
}

# Fake secrets are built at runtime so the test file itself doesn't trip secret scanners (e.g. GitHub push protection)
$ghp     = 'gh' + 'p_' + ('A1b2' * 9)
$aws     = 'AK' + 'IA' + 'ABCDEFGHIJ123456'
$entra   = 'abc8' + 'Q~' + ('xY1_' * 8) + 'zz'
$pat52   = ('ab12' * 13)
$pat84   = ('Ab12' * 21)
$stKey   = ('Ab1/' * 21) + 'Ab' + '=='
$basic   = 'dXNlcjpwYXNzd29yZA=='
$gitHash = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2'

Write-Host "`nSecrets" -ForegroundColor Cyan
$cases = @(
    @{ n = 'quoted value with spaces';   i = '"password": "my secret pass"';             leak = 'my secret pass', 'secret pass' }
    @{ n = 'quoted, short';              i = '"pwd": "abc"';                             leak = 'abc' }
    @{ n = 'unquoted to end of line';    i = 'password: hunter two words';               leak = 'hunter', 'two words' }
    @{ n = 'key=value; delimited';       i = 'Server=x;Password=Sup3r S3cret;User=y';   leak = 'Sup3r' }
    @{ n = 'clientSecret JSON';          i = '{"clientSecret":"s3cr3t value"}';          leak = 's3cr3t' }
    @{ n = 'Authorization Basic';        i = "Authorization: Basic $basic";              leak = $basic }
    @{ n = 'x-api-key header';           i = 'x-api-key: 0123456789abcdef';              leak = '0123456789abcdef' }
    @{ n = 'Ocp-Apim-Subscription-Key';  i = 'Ocp-Apim-Subscription-Key: fedcba9876543210'; leak = 'fedcba9876543210' }
    @{ n = 'GitHub PAT';                 i = "token is $ghp ok";                          leak = $ghp }
    @{ n = 'AWS access key';             i = "key $aws here";                             leak = $aws }
    @{ n = 'Entra client secret';        i = "secret value $entra end";                   leak = $entra }
    @{ n = 'ADO PAT classic (52)';       i = "pat $pat52 end";                            leak = $pat52 }
    @{ n = 'ADO PAT new (84)';           i = "pat $pat84 end";                            leak = $pat84 }
    @{ n = 'Storage key (bare)';         i = "key $stKey end";                            leak = $stKey }
    @{ n = 'URL password';               i = 'http://admin:hunter22@proxy:8080';          leak = 'hunter22' }
    @{ n = 'SAS sig';                    i = 'https://x.blob.core.windows.net/c?sv=1&sig=SIGVALUE123'; leak = 'SIGVALUE123' }
)
foreach ($c in $cases) {
    $out = Invoke-Redact $c.i
    $leaked = @($c.leak | Where-Object { $out.Contains($_) })
    Assert $c.n ($leaked.Count -eq 0 -and $out -match '<redacted:') "-> $out"
}

$out = Invoke-Redact "Thumbprint: $($gitHash.ToUpper())"
Assert 'thumbprint -> reversible placeholder' ($out -eq 'Thumbprint: THUMBPRINT01') "-> $out"

Write-Host "`nNo false positives" -ForegroundColor Cyan
$out = Invoke-Redact "commit $gitHash merged"
Assert 'git commit hash kept' ($out -eq "commit $gitHash merged") "-> $out"
$out = Invoke-Redact 'Graph app 00000003-0000-0000-c000-000000000000'
Assert 'ignored well-known GUID kept' ($out -eq 'Graph app 00000003-0000-0000-c000-000000000000') "-> $out"
$out = Invoke-Redact 'tokenizer settings are fine'
Assert 'word containing "token" untouched' ($out -eq 'tokenizer settings are fine') "-> $out"

Write-Host "`nRestore" -ForegroundColor Cyan
$orig = "fjordtek and Fjordtek AS, FJORDTEK\\ola, ola@fjordtek.no from 10.1.1.1 on SRV-APP01, app fjordtekapp, Nordmann, Ola"
$anon = Invoke-Redact $orig
$back = Invoke-Redact $anon -Restore
Assert 'round trip incl. case, word-internal and reversed name' ($back -eq $orig) "-> $back"
$back = Invoke-Redact 'contosoapp, 192.0.2.15, SERVER12' -Restore
Assert 'numbered placeholders whole-token only; literals inside words' ($back -eq 'fjordtekapp, 192.0.2.15, SERVER12') "-> $back"
$back = Invoke-Redact 'Contoso and CONTOSO and PERSON ONE' -Restore
Assert 'restore keeps the AI''s capitalisation' ($back -eq 'Fjordtek and FJORDTEK and OLA NORDMANN') "-> $back"
$again = Invoke-Redact $orig
Assert 'consistent placeholders across runs' ($again -eq $anon) "-> $again"

Write-Host "`nSharePoint hosts" -ForegroundColor Cyan
$spo = 'https://fjordtek.sharepoint.com/ https://fjordtek-admin.sharepoint.com/ https://fjordtek-my.sharepoint.com/'
$out = Invoke-Redact $spo
Assert 'mapped tenant uses literal placeholder, keeps -admin/-my' ($out -eq 'https://contoso.sharepoint.com/ https://contoso-admin.sharepoint.com/ https://contoso-my.sharepoint.com/') "-> $out"
$back = Invoke-Redact $out -Restore
Assert 'mapped tenant round trip' ($back -eq $spo) "-> $back"
$spo = 'https://acmetenant.sharepoint.com/ https://acmetenant-admin.sharepoint.com/ https://acmetenant-my.sharepoint.com/'
$out = Invoke-Redact $spo
Assert 'unmapped tenant shares one number, keeps -admin/-my' ($out -match '^https://(resource\d+)\.sharepoint\.com/ https://\1-admin\.sharepoint\.com/ https://\1-my\.sharepoint\.com/$') "-> $out"
$back = Invoke-Redact $out -Restore
Assert 'unmapped tenant round trip' ($back -eq $spo) "-> $back"

Write-Host "`nLeaks found by the independent test run" -ForegroundColor Cyan
$leakCases = @(
    @{ n = 'ADO org in git clone URL';      i = 'git clone https://acmeorg@dev.azure.com/acmeorg/x/_git/web'; leak = 'acmeorg' }
    @{ n = 'Password with spaces in connstr'; i = 'Password=my pass word;Encrypt=True';                    leak = 'pass word' }
    @{ n = 'customer name in other hosts';  i = 'fjordtek-my.sharepoint.com fjordtek.onmicrosoft.com';    leak = 'fjordtek' }
    @{ n = 'unmapped Azure hosts';          i = 'acme-sql01.database.windows.net acme.openai.azure.com';   leak = 'acme' }
    @{ n = 'guest UPN';                     i = 'ola.nordmann_fjordtek.no#EXT#@acme.onmicrosoft.com';      leak = 'nordmann', 'acme' }
    @{ n = 'person name variants';          i = 'Nordmann, Ola / ola.nordmann / Ola  Nordmann';            leak = 'nordmann' }
    @{ n = 'user profile path';             i = 'C:\Users\jdoe\AppData and C:\\Users\\jdoe\\x';   leak = 'jdoe' }
    @{ n = 'UNC and SQL host';              i = '\\FILESRV01\share Data Source=SQLPROD01;';             leak = 'FILESRV01', 'SQLPROD01' }
    @{ n = '-ClientSecret parameter';       i = "Connect-PnPOnline -ClientSecret 'abc def'";               leak = 'abc def' }
)
foreach ($c in $leakCases) {
    $out = Invoke-Redact $c.i
    $leaked = @($c.leak | Where-Object { $out -match [regex]::Escape($_) })
    Assert $c.n ($leaked.Count -eq 0) "-> $out"
}

Write-Host "`nRobustness" -ForegroundColor Cyan
Push-Location $tmp
try   { $out = Invoke-Redact 'fjordtek' -Mapping 'mapping.json'; Assert 'relative -MappingPath' ($out -eq 'contoso') "-> $out" }
catch { Assert 'relative -MappingPath' $false $_ }
finally { Pop-Location }

$ips = (1..300 | ForEach-Object { "10.9.$([math]::Floor($_ / 250)).$($_ % 250 + 1)" }) -join ' '
$out = Invoke-Redact $ips
$valid = @($out -split ' ' | Where-Object { $_ -notmatch '^(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)$' })
Assert '300 IPs -> all valid placeholders' ($valid.Count -eq 0) "invalid: $($valid | Select-Object -First 3)"

$badMap = Join-Path $tmp 'bad.json'
'{ "replacements": [ { "find": "", "replace": "X" }, { "find": "fjordtek", "replace": "contoso" } ] }' | Set-Content $badMap
$out = Invoke-Redact 'abc fjordtek' -Mapping $badMap
Assert 'empty "find" skipped' ($out -eq 'abc contoso') "-> $out"

$in = Join-Path $tmp 'in.txt'; 'fjordtek' | Set-Content $in
& $script -Path $in -NoClipboard -Quiet -MappingPath (Join-Path $tmp 'missing.json') 2>$null | Out-Null
Assert 'missing mapping fails closed (exit 2)' ($LASTEXITCODE -eq 2) "exit=$LASTEXITCODE"

'{ "replacements": [ { "find": "a1", "replace": "contoso" }, { "find": "b2", "replace": "Contoso" } ] }' | Set-Content $badMap
$failed = $false; try { & $script -Path $in -NoClipboard -Quiet -MappingPath $badMap 2>$null | Out-Null } catch { $failed = $true }
Assert 'case-only placeholder collision rejected' $failed

Remove-Item $tmp -Recurse -Force
Write-Host "`n$($script:pass) passed, $($script:fail) failed" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
