<#
.SYNOPSIS
    Anonymises (and restores) text before you paste it into an AI tool.

.DESCRIPTION
    Default: reads the clipboard, anonymises it, writes the result back to the clipboard.
    -Paste   : opens a paste window (handles large logs) instead of reading the clipboard.
    -Path    : reads a file instead.
    -Restore : reverses placeholders in the AI's answer back to real values.

    Three kinds of rules, applied in this order:
      1. Secrets   -> <redacted:type>       (irreversible, never restored)
      2. Patterns  -> numbered placeholders (GUIDs, emails, hosts, user paths, IPs, custom regex; reversible)
      3. Literals  -> fixed replacements from mapping.json (customer names, people; reversible, case-preserving)

    Reversible placeholders are stored in mapping.auto.json next to mapping.json, so the
    same value always gets the same placeholder across runs. Both files are git-ignored.

    Works in Windows PowerShell 5.1 and PowerShell 7+.

.NOTES
    TODO (improvement, undecided):
      mapping.auto.json holds the REAL values in plain text, next to mapping.json (by default
      inside the repo folder). It is git-ignored, but the folder may be synced (OneDrive etc.),
      and one file mixes values from every customer you use the same mapping for.
      Option: default to %LOCALAPPDATA%\redact\<customer>\ (one mapping + auto map per customer,
      selected with -Customer or $env:REDACT_MAPPING), and/or encrypt it with DPAPI
      (ConvertFrom-SecureString) so it is only readable by your Windows user.

.EXAMPLE
    .\Redact.ps1                 # anonymise clipboard -> clipboard
    .\Redact.ps1 -Paste          # paste window -> clipboard
    .\Redact.ps1 -Restore        # restore clipboard -> clipboard
    .\Redact.ps1 -Path .\app.log -NoClipboard > app.redacted.log
    .\Redact.ps1 -Reset          # forget generated placeholders
#>
[CmdletBinding()]
param(
    [switch]$Restore,
    [switch]$Paste,
    [string]$Path,
    [string]$MappingPath = $(if ($env:REDACT_MAPPING) { $env:REDACT_MAPPING } else { Join-Path $PSScriptRoot 'mapping.json' }),
    [switch]$AllowNoMapping,
    [switch]$NoClipboard,
    [switch]$Show,
    [switch]$Quiet,
    [switch]$Reset
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve relative paths against the current PowerShell location (not the process working directory)
$MappingPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($MappingPath)
$AutoMapPath = Join-Path ([IO.Path]::GetDirectoryName($MappingPath)) 'mapping.auto.json'
$OnWindows   = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT   # $IsWindows doesn't exist in 5.1

#region Built-in rules ------------------------------------------------------------------
# Secrets: irreversible. If the regex has a group named 'v', only that part is redacted; otherwise the whole match.
# Values true/false/null are never redacted. Order matters: specific formats first, generic key/value last.
$KeyNames = 'password|passwd|pwd|secret|client_?secret|api_?key|access_?key|token|access_?token|refresh_?token|private_?key'
$Quoted   = "`"(?<v>[^`"\r\n]*)`"|'(?<v>[^'\r\n]*)'"
$BuiltInSecrets = @(
    @{ name = 'privatekey';   regex = '-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]+?-----END [A-Z ]*PRIVATE KEY-----' }
    @{ name = 'jwt';          regex = 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' }
    @{ name = 'bearer';       regex = '(?i)(?<=\bBearer\s+)(?<v>[A-Za-z0-9\-._~+/]{20,}=*)' }
    @{ name = 'basic';        regex = '(?i)(?<=\bBasic\s+)(?<v>[A-Za-z0-9+/]{8,}={0,2})' }
    @{ name = 'github';       regex = '\b(?:gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{60,255})\b' }
    @{ name = 'aws';          regex = '\b(?:AKIA|ASIA)[0-9A-Z]{16}\b' }
    @{ name = 'entra-secret'; regex = '(?<![A-Za-z0-9_.~-])[A-Za-z0-9_.-]{3,6}Q~[A-Za-z0-9_.~-]{30,40}(?![A-Za-z0-9_.~-])' }
    @{ name = 'ado-pat';      regex = '\b[A-Za-z0-9]{84}\b' }   # new 84-char Azure DevOps PAT
    @{ name = 'ado-pat';      regex = '\b[a-z0-9]{52}\b' }      # classic 52-char Azure DevOps PAT
    @{ name = 'storage-key';  regex = '(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{86}==' }
    @{ name = 'sas';          regex = '(?<=[?&]sig=)(?<v>[^&\s"'']+)' }
    @{ name = 'query-secret'; regex = '(?i)(?<=[?&](?:code|key|apikey|api_key|api-key|access_token|id_token|refresh_token|client_secret|password|subscription-key)=)(?<v>[^&\s"''#]+)' }
    @{ name = 'webhook';      regex = '(?i)(?<=/IncomingWebhook/)(?<v>[A-Za-z0-9]+)' }
    @{ name = 'url-password'; regex = '(?<=://[^:/\s@]+:)(?<v>[^@/\s]+)(?=@)' }
    @{ name = 'curl-user';    regex = '(?m)(?<=(?:^|\s)(?:-u|--user)\s+["'']?[^:\s"'']+:)(?<v>[^\s"'']+)' }
    @{ name = 'connstr';      regex = '(?i)(?<=\b(?:AccountKey|SharedAccessKey)\s*=\s*)(?<v>[^;&\s"'',]+)' }
    @{ name = 'header-key';   regex = '(?i)(?<=\b(?:x-api-key|api-key|ocp-apim-subscription-key|x-functions-key)["'']?\s*[:=]\s*["'']?)(?<v>[^\s"'',;]+)' }
    @{ name = 'config-value'; regex = "(?i)<add\s+key\s*=\s*`"[^`"]*(?:$KeyNames)[^`"]*`"\s+value\s*=\s*`"(?<v>[^`"]*)`"" }   # web.config / app.config
    @{ name = 'securestring'; regex = "(?i)(?<=ConvertTo-SecureString\s+(?:-String\s+)?)(?:$Quoted)" }
    @{ name = 'ps-param';     regex = "(?i)(?<=(?<![\w-])--?[A-Za-z]*(?:$KeyNames)\s+)(?:$Quoted|(?<v>(?![(`$@-])[^\s;|)]+))" }   # -ClientSecret 'x', --password x
    # Generic key/value (prefix allowed: AZURE_CLIENT_SECRET, userPWD, dbPassword). Quoted values may contain spaces;
    # unquoted values run to the next , ; } & or end of line.
    @{ name = 'kv-pair';      regex = "(?im)(?<=(?<![A-Za-z0-9])[A-Za-z0-9_-]*(?:$KeyNames)[`"']?\s*[:=]\s*)(?:$Quoted|(?<v>[^\s`"',;}&][^\r\n`"',;}&]*?)(?=[ \t]*(?:[,;}&\r\n]|$)))" }
)

# Reversible patterns. {n} = running number per pattern ({n:000} for zero padding), {ip} = documentation-range IP.
# A group named 'v' limits the replacement to that part of the match. Patterns sharing a name share numbering.
$AzureHostSuffix = 'database\.windows\.net|vault\.azure\.net|azurewebsites\.net|servicebus\.windows\.net|azure-api\.net|azurecr\.io|azure-devices\.net|documents\.azure\.com|search\.windows\.net|redis\.cache\.windows\.net|postgres\.database\.azure\.com|mysql\.database\.azure\.com|azurefd\.net|azureedge\.net|azurestaticapps\.net|azurecontainerapps\.io|openai\.azure\.com|cognitiveservices\.azure\.com|azconfig\.io|service\.signalr\.net|eventgrid\.azure\.net|cloudapp\.azure\.com|trafficmanager\.net|kusto\.windows\.net|crm\d*\.dynamics\.com|onmicrosoft\.com|visualstudio\.com'
$HttpServers = 'Kestrel|nginx|Apache|cloudflare|Microsoft-IIS|Microsoft-HTTPAPI|Microsoft-Azure-Application-Gateway|Windows-Azure-Blob|Windows-Azure-Web|AmazonS3|gws|ESF|envoy|openresty|LiteSpeed|Caddy'
$NotDomains = 'HKLM|HKCU|HKCR|HKU|HKCC|HKEY_[A-Z_]+|AUTHORITY|BUILTIN|SERVICE|APPPOOL|WORKGROUP|SYSTEM32|SOFTWARE|SYSTEM|WINDOWS'
$BuiltInPatterns = @(
    @{ name = 'guid';       regex = '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'; replace = '00000000-0000-0000-0000-{n:000000000000}' }
    @{ name = 'winuser';    regex = '(?<=://)(?<v>[\p{L}\p{N}._%+-]+)(?=(?::[^@/\s]*)?@)'; replace = 'winuser{n}' }   # user@ in URLs (git clone)
    @{ name = 'email';      regex = '[\p{L}\p{N}._%+\-]+#EXT#@[\p{L}\p{N}.\-]+\.\p{L}{2,}\b'; replace = 'user{n}@example.com' }   # Entra guest UPN
    @{ name = 'email';      regex = '(?<!://)\b[\p{L}\p{N}._%+\-]+@[\p{L}\p{N}.\-]+\.\p{L}{2,}\b(?!:)'; replace = 'user{n}@example.com' }
    @{ name = 'email-enc';  regex = '\b[\p{L}\p{N}._+\-]+%40[\p{L}\p{N}.\-]+\.\p{L}{2,}\b'; replace = 'user{n}%40example.com' }
    @{ name = 'onedrive';   regex = '(?i)(?<=/personal/)(?<v>[A-Za-z0-9_]+)(?=[/?#"''\s]|$)'; replace = 'user{n}_example_com' }
    @{ name = 'storage';    regex = '(?i)(?<=AccountName=)[a-z0-9]{3,24}|\b[a-z0-9]{3,24}(?=\.(?:blob|queue|table|file|dfs|web)\.core\.windows\.net)'; replace = 'storageaccount{n}' }
    @{ name = 'azure-host'; regex = '(?i)(?<![A-Za-z0-9.-])(?<v>[a-z0-9][a-z0-9-]{0,62}?)(?=(?:-(?:admin|my))?\.sharepoint\.com\b)'; replace = 'resource{n}' }   # SharePoint tenant; -admin/-my kept so they share the tenant's number
    @{ name = 'azure-host'; regex = "(?i)(?<![A-Za-z0-9.-])(?<v>[a-z0-9][a-z0-9-]{0,62})(?=(?:\.[a-z0-9-]+)*?\.(?:scm\.)?(?:$AzureHostSuffix)\b)"; replace = 'resource{n}' }
    @{ name = 'azure-host'; regex = '(?i)(?<=\bdev\.azure\.com/)(?<v>[A-Za-z0-9][A-Za-z0-9-]{0,49})'; replace = 'resource{n}' }   # ADO org in URL
    @{ name = 'host';       regex = '\b[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)*\.(?:local|lan|corp|internal|intra|intranet|ad|localdomain|LOCAL|LAN|CORP|INTERNAL|INTRA|INTRANET|AD|LOCALDOMAIN)\b(?!\.[A-Za-z])'; replace = 'host{n}.internal' }   # case-sensitive TLD, so .NET namespaces (.Internal.) survive
    @{ name = 'host';       regex = '(?<![\w:\\])\\\\(?<v>[A-Za-z0-9][A-Za-z0-9-]{0,62})(?=\\)'; replace = 'host{n}' }   # UNC \\server\share
    @{ name = 'host';       regex = "(?i)(?<=\b(?:computer ?name|machine ?name|host ?name|hostname|device ?name|node ?name|server)[`"']?\s*[:=]\s*[`"']?)(?!(?:tcp|np|lpc):)(?!(?:$HttpServers)\b)(?<v>[A-Za-z][A-Za-z0-9-]{1,62})(?![A-Za-z0-9-]*[(/])"; replace = 'host{n}' }   # HTTP 'Server: Kestrel' etc. excluded
    @{ name = 'host';       regex = '(?i)(?<=\b(?:data source|address|addr|host)\s*=\s*["'']?)(?!(?:tcp|np|lpc):)(?<v>[A-Za-z][A-Za-z0-9-]{1,62})(?![A-Za-z0-9-]*[(/])'; replace = 'host{n}' }   # connection strings (= only, so HTTP "Server:" headers survive)
    @{ name = 'winuser';    regex = '(?i)(?<=\b[A-Za-z]:\\{1,2}Users\\{1,2}|/home/|/Users/)(?!(?:Public|Default|All Users|Default User)(?:[\\/\s]|$))(?<v>[^\\/\s"''<>|:*?]+)'; replace = 'winuser{n}' }
    @{ name = 'winuser';    regex = "(?<![\\/:A-Za-z0-9])(?!(?:$NotDomains)\\)(?:[A-Z][A-Z0-9-]{1,14})\\(?<v>[A-Za-z][A-Za-z0-9._-]{1,63})\b"; replace = 'winuser{n}' }   # DOMAIN\user
    @{ name = 'thumbprint'; regex = '(?i)(?<=(?:thumbprint|x5t)["'']?\s*[:=]?\s*["'']?)(?<v>[0-9a-f]{40})\b'; replace = 'THUMBPRINT{n:00}' }   # identifier, not a secret; contextual so git hashes survive
    @{ name = 'ipv4';       regex = '(?<!(?i:version|ver)[\s=:"'']{0,3})(?<![vV\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![.\d])'; replace = '{ip}' }
)
# Your own machine and Windows account, whole word, wherever they appear
foreach ($pair in @(@('machine', $env:COMPUTERNAME, 'machine{n}'), @('winuser', $env:USERNAME, 'winuser{n}'))) {
    if (-not [string]::IsNullOrWhiteSpace($pair[1]) -and $pair[1].Length -ge 3) {
        $BuiltInPatterns += @{ name = $pair[0]; regex = '(?i)(?<![A-Za-z0-9])' + [regex]::Escape($pair[1]) + '(?![A-Za-z0-9])'; replace = $pair[2] }
    }
}
#endregion

#region Helpers ---------------------------------------------------------------------------
function Write-Status([string]$msg, [string]$color = 'Green') {
    if ($Quiet) { return }
    # stderr when output goes to stdout, so redirected output stays clean
    if ($NoClipboard) { [Console]::Error.WriteLine($msg) } else { Write-Host $msg -ForegroundColor $color }
}

function ConvertTo-Hashtable($obj) {
    # PS 5.1-compatible replacement for ConvertFrom-Json -AsHashtable
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]) { return @($obj | ForEach-Object { ConvertTo-Hashtable $_ }) }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }
        return $h
    }
    return $obj
}

function Read-JsonFile([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $raw = Get-Content -LiteralPath $file -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    ConvertTo-Hashtable ($raw | ConvertFrom-Json)
}

function Get-TestNetIp([int]$n) {
    # RFC 5737 documentation ranges (762 addresses), then RFC 2544 benchmark range 198.18.0.0/15
    if ($n -le 254) { return "192.0.2.$n" }
    if ($n -le 508) { return "198.51.100.$($n - 254)" }
    if ($n -le 762) { return "203.0.113.$($n - 508)" }
    $k = $n - 763
    $third = [math]::Floor($k / 254); $fourth = ($k % 254) + 1
    return "198.$(18 + [math]::Floor($third / 256)).$($third % 256).$fourth"
}

function Format-Placeholder([string]$template, [int]$n) {
    if ($template -eq '{ip}') { return Get-TestNetIp $n }
    [regex]::Replace($template, '\{n(?::(?<f>[^}]+))?\}', {
        param($m) if ($m.Groups['f'].Success) { $n.ToString($m.Groups['f'].Value) } else { "$n" }
    })
}

function Convert-Case([string]$matched, [string]$canonical, [string]$target) {
    # Carry the capitalisation of the matched text over to the replacement:
    # as written -> target as written; ALL CAPS -> ALL CAPS; lower -> lower; Capitalised -> Capitalised.
    if ($matched -ceq $canonical) { return $target }
    $letters = $matched -replace '[^\p{L}]', ''
    if (-not $letters) { return $target }
    $upper = $letters.ToUpperInvariant(); $lower = $letters.ToLowerInvariant()
    if ($letters -ceq $upper -and $upper -cne $lower) { return $target.ToUpperInvariant() }
    if ($letters -ceq $lower) { return $target.ToLowerInvariant() }
    if ([char]::IsUpper($letters[0]) -and $letters.Substring(1) -ceq $letters.Substring(1).ToLowerInvariant() -and $target.Length) {
        return $target.Substring(0, 1).ToUpperInvariant() + $target.Substring(1).ToLowerInvariant()
    }
    return $target
}

# Literal phrase -> regex. Multi-word phrases with the same word count on both sides also match
# other separators (Ola.Nordmann, ola_nordmann, Ola  Nordmann) and, for two words, "Nordmann, Ola".
$Sep = '[\s._-]+'
function Get-PhraseRegex([string[]]$srcWords, [int]$dstCount, [bool]$wholeWord) {
    $esc = [string[]]@($srcWords | ForEach-Object { [regex]::Escape($_) })
    if ($esc.Length -eq 1) { $rx = $esc[0] }
    elseif ($esc.Length -eq $dstCount) {
        $rx = $esc -join $Sep
        if ($esc.Length -eq 2) { $rx = "$rx|$($esc[1]),\s*$($esc[0])" }
    }
    else { $rx = $esc -join '\s+' }
    if ($wholeWord -or $esc.Length -gt 1) { "(?<![\p{L}\p{N}])(?:$rx)(?![\p{L}\p{N}])" } else { "(?:$rx)" }
}

function Convert-Phrase([string]$matched, [string[]]$srcWords, [string[]]$dstWords, [string]$dst) {
    if ($srcWords.Length -eq 1 -or $srcWords.Length -ne $dstWords.Length) { return Convert-Case $matched ($srcWords -join ' ') $dst }
    $parts = [regex]::Split($matched, '([\s._,-]+)')
    $words = [string[]]@(for ($i = 0; $i -lt $parts.Length; $i += 2) { $parts[$i] })
    $seps  = [string[]]@(for ($i = 1; $i -lt $parts.Length; $i += 2) { $parts[$i] })
    if ($words.Length -ne $srcWords.Length) { return Convert-Case $matched ($srcWords -join ' ') $dst }
    $s = [string[]]@($srcWords); $d = [string[]]@($dstWords)
    if ($matched.Contains(',')) { [array]::Reverse($s); [array]::Reverse($d) }
    $out = ''
    for ($i = 0; $i -lt $words.Length; $i++) {
        $out += Convert-Case $words[$i] $s[$i] $d[$i]
        if ($i -lt $seps.Length) { $out += $seps[$i] }
    }
    $out
}

function Split-Words([string]$s) { @($s.Trim() -split '\s+') }

function Show-PasteDialog {
    if (-not $OnWindows) {
        Write-Host 'Paste text, then Ctrl+D (Linux/macOS) to finish:' -ForegroundColor Cyan
        return [Console]::In.ReadToEnd()
    }
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $title = if ($Restore) { 'Paste AI answer to restore' } else { 'Paste text to anonymise' }
    $form = New-Object Windows.Forms.Form
    $form.Text = "$title  (Ctrl+Enter = OK, Esc = cancel)"
    $form.Size = [Drawing.Size]::new(900, 600)
    $form.StartPosition = 'CenterScreen'; $form.TopMost = $true; $form.KeyPreview = $true

    $box = New-Object Windows.Forms.TextBox
    $box.Multiline = $true; $box.ScrollBars = 'Both'; $box.WordWrap = $false; $box.MaxLength = 0
    $box.Dock = 'Fill'; $box.AcceptsTab = $true; $box.Font = [Drawing.Font]::new('Consolas', 10)

    $ok = New-Object Windows.Forms.Button
    $ok.Text = 'OK'; $ok.Dock = 'Bottom'; $ok.Height = 32; $ok.DialogResult = 'OK'

    $form.Controls.AddRange(@($box, $ok))
    $form.Add_KeyDown({
        if ($_.Control -and $_.KeyCode -eq 'Return') { $form.DialogResult = 'OK'; $form.Close() }
        elseif ($_.KeyCode -eq 'Escape') { $form.DialogResult = 'Cancel'; $form.Close() }
    })
    $form.Add_Shown({ $box.Focus() })
    $result = $form.ShowDialog()
    $text = $box.Text
    $form.Dispose()
    if ($result -ne [Windows.Forms.DialogResult]::OK) { return $null }
    $text
}
#endregion

#region Load state -----------------------------------------------------------------------
if ($Reset) {
    if (Test-Path -LiteralPath $AutoMapPath) { Remove-Item -LiteralPath $AutoMapPath; Write-Host "Removed $AutoMapPath" -ForegroundColor Yellow }
    return
}

$mapping = Read-JsonFile $MappingPath
if (-not $mapping) {
    # Fail closed: a typo in the path would otherwise silently leak every customer name.
    if (-not $AllowNoMapping) {
        Write-Error "No mapping file at $MappingPath. Copy mapping.example.json to mapping.json, fix the path, or use -AllowNoMapping to run with built-in rules only." -ErrorAction Continue
        exit 2
    }
    Write-Warning "No mapping file at $MappingPath. Running with built-in rules only (-AllowNoMapping)."
    $mapping = @{}
}

# Literals: validate. Placeholders are compared ignoring case (restore is case-insensitive),
# so two different values must not share a placeholder that differs only by case.
$literals = @()
$byPlaceholder = @{}   # case-insensitive: placeholder -> find
foreach ($l in @(if ($mapping.Contains('replacements')) { $mapping['replacements'] })) {
    if ($null -eq $l -or [string]::IsNullOrWhiteSpace($l['find'])) { Write-Warning 'Skipping replacement with empty "find".'; continue }
    if ([string]::IsNullOrWhiteSpace($l['replace'])) { throw "Mapping error: replacement for '$($l['find'])' has an empty ""replace"". Use a placeholder such as 'contoso'." }
    $ph = $l['replace']
    if ($byPlaceholder.ContainsKey($ph) -and $byPlaceholder[$ph] -ne $l['find']) {
        throw "Mapping error: placeholder '$ph' is used for both '$($byPlaceholder[$ph])' and '$($l['find'])'. Placeholders are compared ignoring case, so give each value a distinct placeholder (e.g. 'contoso' and 'Contoso Ltd')."
    }
    $byPlaceholder[$ph] = $l['find']
    $literals += [pscustomobject]@{
        find = $l['find']; replace = $ph
        findWords = [string[]]@(Split-Words $l['find']); replaceWords = [string[]]@(Split-Words $ph)
        wholeWord = [bool]($l.Contains('wholeWord') -and $l['wholeWord'])
    }
}

$secrets  = @($BuiltInSecrets)  + @(if ($mapping.Contains('secretPatterns')) { $mapping['secretPatterns'] })
$patterns = @($BuiltInPatterns) + @(if ($mapping.Contains('patterns'))       { $mapping['patterns'] })
$ignoreSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($i in @(if ($mapping.Contains('ignore')) { $mapping['ignore'] })) { [void]$ignoreSet.Add($i) }
$keepValues = [System.Collections.Generic.HashSet[string]]::new([string[]]@('true', 'false', 'null'), [StringComparer]::OrdinalIgnoreCase)

# auto map: patternName -> { original -> placeholder }  ([ordered] is case-insensitive, so GUID/email casing doesn't matter)
$auto = Read-JsonFile $AutoMapPath
if (-not $auto) { $auto = [ordered]@{} }
foreach ($p in $patterns) { if (-not $auto.Contains($p.name)) { $auto[$p.name] = [ordered]@{} } }

# All existing placeholders (numbered + literal), for O(1) "already anonymised?" checks
$placeholderSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($name in @($auto.Keys)) { foreach ($v in @($auto[$name].Values)) { [void]$placeholderSet.Add($v) } }
foreach ($l in $literals) { [void]$placeholderSet.Add($l.replace) }

# Values mapped explicitly in replacements are left to the literal step, so the user's own placeholder wins
$literalFinds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($l in $literals) { [void]$literalFinds.Add($l.find) }
#endregion

#region Input ----------------------------------------------------------------------------
$text = if ($Path) { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 }
        elseif ($Paste) { Show-PasteDialog }
        else { Get-Clipboard -Raw }

if ([string]::IsNullOrEmpty($text)) { Write-Warning 'Nothing to process (empty input or cancelled).'; return }
#endregion

$stats = [ordered]@{}
function Add-Stat($k) { if ($stats.Contains($k)) { $stats[$k]++ } else { $stats[$k] = 1 } }

# One-pass literal replacement (both directions). Longest phrase first; named group per literal.
function Invoke-Literals([string]$text, [bool]$toPlaceholder) {
    if (@($literals).Length -eq 0) { return $text }
    $i = 0
    $items = foreach ($l in $literals) {
        $src = [string[]]@(if ($toPlaceholder) { $l.findWords } else { $l.replaceWords })
        $dst = [string[]]@(if ($toPlaceholder) { $l.replaceWords } else { $l.findWords })
        [pscustomobject]@{
            g = "L$i"; src = $src; dst = $dst; n = $dst.Length; dstText = ($dst -join ' ')
            len = ($src -join ' ').Length; rx = Get-PhraseRegex $src $dst.Length $l.wholeWord
        }
        $i++
    }
    $items = @($items | Sort-Object len -Descending)
    $alt = ($items | ForEach-Object { "(?<$($_.g)>$($_.rx))" }) -join '|'
    [regex]::Replace($text, "(?i)$alt", {
        param($m)
        foreach ($it in $items) {
            if ($m.Groups[$it.g].Success) {
                Add-Stat $(if ($toPlaceholder) { 'literal' } else { 'restored' })
                return Convert-Phrase $m.Value $it.src $it.dst $it.dstText
            }
        }
        $m.Value
    })
}

if (-not $Restore) {
    #region Anonymise ---------------------------------------------------------------------
    # 1. Secrets (irreversible)
    foreach ($s in $secrets) {
        $name = $s.name
        $text = [regex]::Replace($text, $s.regex, {
            param($m)
            $g = $m.Groups['v']
            $val = if ($g.Success) { $g.Value } else { $m.Value }
            if ([string]::IsNullOrEmpty($val) -or $val.StartsWith('<redacted') -or $ignoreSet.Contains($val) -or $keepValues.Contains($val.Trim())) { return $m.Value }
            Add-Stat "secret:$name"
            if (-not $g.Success) { return "<redacted:$name>" }
            $start = $g.Index - $m.Index
            $m.Value.Substring(0, $start) + "<redacted:$name>" + $m.Value.Substring($start + $g.Length)
        })
    }

    # 2. Reversible patterns (consistent numbering, persisted)
    foreach ($p in $patterns) {
        $name = $p.name; $tpl = $p.replace; $map = $auto[$name]
        $text = [regex]::Replace($text, $p.regex, {
            param($m)
            $g = $m.Groups['v']
            $v = if ($g.Success) { $g.Value } else { $m.Value }
            if ([string]::IsNullOrEmpty($v) -or $ignoreSet.Contains($v) -or $placeholderSet.Contains($v) -or $literalFinds.Contains($v)) { return $m.Value }   # ignored, already a placeholder, or mapped in replacements
            if (-not $map.Contains($v)) {
                $ph = Format-Placeholder $tpl ($map.Count + 1)
                $map[$v] = $ph; [void]$placeholderSet.Add($ph)
            }
            Add-Stat $name
            if (-not $g.Success) { return $map[$v] }
            $start = $g.Index - $m.Index
            $m.Value.Substring(0, $start) + $map[$v] + $m.Value.Substring($start + $g.Length)
        })
    }

    # 3. Literals (case-insensitive, case-preserving; inside longer words unless wholeWord or multi-word)
    $text = Invoke-Literals $text $true

    $auto | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $AutoMapPath -Encoding UTF8
    #endregion
}
else {
    #region Restore -----------------------------------------------------------------------
    # Inverse order of anonymise: literals first, then numbered placeholders.
    # Literal placeholders: case-insensitive, case-preserving, inside longer words unless wholeWord.
    # Numbered placeholders: whole tokens only (192.0.2.1 not inside 192.0.2.15).
    $text = Invoke-Literals $text $false
    $reverse = @{}   # case-insensitive: placeholder -> original
    $alts = @()
    foreach ($name in @($auto.Keys)) {
        foreach ($orig in @($auto[$name].Keys)) {
            $ph = $auto[$name][$orig]
            if ($reverse.ContainsKey($ph)) { continue }
            $reverse[$ph] = $orig
            $alts += [pscustomobject]@{ len = $ph.Length; rx = '(?<![A-Za-z0-9])' + [regex]::Escape($ph) + '(?![A-Za-z0-9])' }
        }
    }
    if ($alts.Count) {
        $alt = ($alts | Sort-Object len -Descending | ForEach-Object { $_.rx }) -join '|'
        $text = [regex]::Replace($text, "(?i)$alt", { param($m) Add-Stat 'restored'; $reverse[$m.Value] })
    }
    if ($text -match '<redacted:') { Write-Status 'Note: <redacted:...> secrets are never restored.' 'Yellow' }
    #endregion
}

#region Output ---------------------------------------------------------------------------
if ($NoClipboard) { $text }
else {
    Set-Clipboard -Value $text
    if ($Show) { Write-Host $text }
}
$summary = if ($stats.Count) { ($stats.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ' } else { 'no matches' }
$verb = if ($Restore) { 'Restored' } else { 'Anonymised' }
$dest = if ($NoClipboard) { 'stdout' } else { 'clipboard' }
Write-Status "$verb $($text.Length) chars -> $dest  [$summary]"
#endregion
