# Redact

Anonymise text before pasting it into an AI tool, and restore the AI's answer afterwards.
Works in Windows PowerShell 5.1 and PowerShell 7+.

## Setup

```powershell
Copy-Item mapping.example.json mapping.json   # mapping.json is git-ignored
# edit mapping.json: replace the fictional 'fjordtek' with your customer
.\Tests\Test-Redact.ps1                       # quick regression tests (5.1 and 7)
pwsh .\Tests\Test-Redact.Spec.ps1             # 193 independent black-box tests (PowerShell 7, ~2.5 min)
```

Optional: keep mappings outside the repo, e.g. per customer:

```powershell
$env:REDACT_MAPPING = "$HOME\.redact\fjordtek\mapping.json"
```

## Usage

| Command | What it does |
|---|---|
| `.\Redact.ps1` | Clipboard → anonymise → clipboard |
| `.\Redact.ps1 -Paste` | Paste window (large logs) → clipboard. `Ctrl+Enter` = OK, `Esc` = cancel |
| `.\Redact.ps1 -Restore` | AI answer in clipboard → real values → clipboard |
| `.\Redact.ps1 -Path app.log -NoClipboard > app.redacted.log` | File → stdout (status line goes to stderr) |
| `.\Redact.ps1 -MappingPath .\other.json` | Use another mapping (relative paths are resolved from the current folder) |
| `.\Redact.ps1 -AllowNoMapping` | Run with built-in rules only. Without it, a missing mapping file stops the script (exit 2), so a typo can't silently leak customer names |
| `.\Redact.ps1 -Show` / `-Quiet` | Also print the result / suppress the status line |
| `.\Redact.ps1 -Reset` | Forget generated placeholders (`mapping.auto.json`) |

To pick an older clipboard item: press `Win+V`, select it, then run the script.

> **Clipboard history keeps the original.** Anything you copy is stored in Windows clipboard
> history (`Win+V`), and synced to other devices if cloud clipboard is on. For sensitive text:
> clear it with `Win+V` → **Clear all**, turn history off under Settings → System → Clipboard,
> or use `-Paste` / `-Path` with text that never went through the clipboard.

## mapping.json

```json
{
  "replacements":   [ { "find": "fjordtek", "replace": "contoso" },
                      { "find": "FJT", "replace": "CTS", "wholeWord": true } ],
  "patterns":       [ { "name": "ticket", "regex": "\\bFJT-\\d+\\b", "replace": "TICKET-{n}" } ],
  "secretPatterns": [ { "name": "vault-ref", "regex": "..." } ],
  "ignore":         [ "00000003-0000-0000-c000-000000000000" ]
}
```

- **Map the customer name itself first.** Literals match inside longer words, so `fjordtek` also covers `fjordtek.no`, `func-fjordtek-prod`, `FJORDTEK-PC042`.
- `wholeWord: true` for short names or abbreviations that would otherwise match inside other words.
- **People:** a multi-word entry such as `Ola Nordmann` → `Person One` also matches `ola.nordmann`, `ola_nordmann`, `Ola  Nordmann` and `Nordmann, Ola`, keeping the separator and order (`person.one`, `One, Person`). Works when both sides have the same number of words.
- Capitalisation is carried over: `FJORDTEK` → `CONTOSO`, `Fjordtek` → `Contoso`, and back.
- Placeholders must be unique **ignoring case**. `contoso` and `Contoso` for two different values is rejected with an error. An empty `replace` is rejected; an empty `find` is skipped with a warning.

## Rules (applied in this order)

1. **Secrets** → `<redacted:type>`. Irreversible.
   - Tokens: JWT, `Bearer`, `Basic`, GitHub (`ghp_…`, `github_pat_…`), AWS (`AKIA…`), Entra client secrets (`…Q~…`), Azure DevOps PATs (52 and 84 chars), bare storage keys (88 chars ending `==`)
   - Context-based: `AccountKey=`, SAS `sig=`, `?code=`/`?key=`/`?access_token=` in URLs, `user:pass@` in URLs, `curl -u user:pass`, Teams webhook URLs, `x-api-key`/`Ocp-Apim-Subscription-Key` headers, `<add key="…Secret…" value="…"/>`, `ConvertTo-SecureString '…'`, `-ClientSecret '…'` / `--password …` parameters (variables like `$secret` are kept)
   - Key/value: keys ending in `password`, `pwd`, `secret`, `clientSecret`, `apiKey`, `accessKey`, `token`, `privateKey` (so `AZURE_CLIENT_SECRET`, `userPWD`, `dbPassword` too). Quoted values may contain spaces; unquoted values are redacted to the next `,` `;` `}` `&` or end of line. `true`/`false`/`null` are kept.
   - Private key blocks
2. **Patterns** → numbered placeholders, reversible:

   | What | Placeholder |
   |---|---|
   | GUIDs | `00000000-0000-0000-0000-000000000001` |
   | Emails (incl. `æøå`, Entra guest UPNs `…#EXT#@…`) / URL-encoded `%40` | `user1@example.com` / `user1%40example.com` |
   | OneDrive `/personal/<user>/` | `user1_example_com` |
   | User in `https://<user>@…` URLs (git clone) | `winuser1` |
   | Storage account names | `storageaccount1` |
   | Azure resource hosts: first label of any host ending in `.sharepoint.com`, `.onmicrosoft.com`, `.database.windows.net`, `.vault.azure.net`, `.azurewebsites.net`, `.azurestaticapps.net`, `.openai.azure.com`, `.crm*.dynamics.com` and ~20 more (full list in the script), plus the org in `dev.azure.com/<org>`. SharePoint `-admin`/`-my` suffixes are kept, so `tenant-admin.sharepoint.com` → `resource1-admin.sharepoint.com` | `resource1` |
   | Internal FQDNs ending in `.local`, `.lan`, `.corp`, `.internal`, `.ad`, … (lower- or upper-case TLD, so .NET namespaces like `.Internal.` are kept) | `host1.internal` |
   | Host after `hostname:`, `computer name:`, `server:` (not HTTP products like `Kestrel`, `Microsoft-IIS/10.0`), `Data Source=`, `host=`, and UNC `\\server\share` | `host1` |
   | User folder in `C:\Users\<name>` (also JSON-escaped `\\`), `/home/<name>`, `/Users/<name>` (not `Public`/`Default`), and `DOMAIN\user` (not `HKLM\`, `NT AUTHORITY\`, `BUILTIN\`, …) | `winuser1` |
   | Your own `%COMPUTERNAME%` / `%USERNAME%` anywhere (whole word) | `machine1` / `winuser1` |
   | Certificate thumbprints after `Thumbprint`/`x5t` (bare 40-hex strings such as git hashes are kept) | `THUMBPRINT01` |
   | IPv4 (documentation ranges, always valid IPs). Version numbers after `Version`/`v` are kept | `192.0.2.1` |
   | Your own `patterns` | as configured |

   The same value always gets the same placeholder (stored in `mapping.auto.json`). Values in `ignore` are never touched. A value that exactly matches a `find` in `replacements` is left for step 3, so your own placeholder wins: with `fjordtek` → `contoso`, `fjordtek-admin.sharepoint.com` becomes `contoso-admin.sharepoint.com`, not `resource1-admin.sharepoint.com`.
3. **Literals** from `replacements` → fixed placeholders. Longest first, case-insensitive.

## Restore

- Case-insensitive and case-preserving: `Contoso` → `Fjordtek`, `CONTOSO` → `FJORDTEK`, `contoso` → `fjordtek`. Mixed case falls back to the spelling in `mapping.json`.
- Literal placeholders are restored inside longer words, mirroring anonymise: `contosoapp` → `fjordtekapp`. With `wholeWord`, only whole words.
- Numbered placeholders are restored as whole tokens only: `192.0.2.1` is not restored inside `192.0.2.15`, `SERVER1` not inside `SERVER12`.
- `<redacted:…>` is never restored.
- Genuine occurrences of a placeholder (e.g. a real `contoso`) are also "restored". Choose placeholders that won't appear in real text.

## Limits

- Regex can't find names in free text it doesn't know about. Add them to `replacements`, and glance at the output before pasting.
- `DOMAIN\user`: the user part is replaced, the domain is not (covered if the domain contains your mapped customer name).
- Person names are only found if they are in `replacements`. Names in free text (`Hilsen Kari`) are not.
- Unquoted `password: …` values are redacted to end of line, which can over-redact. That's deliberate.
- `mapping.auto.json` contains the real values in plain text (see TODO in the script header).
- Throughput is roughly 0.3 MB/s: a 200 KB log takes about 2 s, 6 MB about 20 s. Run `-Reset` now and then to keep `mapping.auto.json` small.
