<#
.SYNOPSIS
    Collects the configuration and credentials that make this Windows machine
    "yours" into a single bundle, ready to scp to the VPS.

.DESCRIPTION
    What travels: agent configs, agent memories, the skills vault, and the .env
    files of the four apps.

    What deliberately does NOT travel:
      * hermes state.db (~370 MB) and sessions/ - a live SQLite file copied
        while Hermes is running is a corrupt SQLite file. Fresh history on the
        VPS is the cheaper trade. Pass -IncludeHermesState to override.
      * caches, logs, node/, sandboxes/, chrome-profile/ - regenerated on use.
      * .bak / .bak-* files - there are a dozen config.yaml backups; none are
        needed on the VPS.

    The bundle contains PLAINTEXT API KEYS AND OAUTH TOKENS. Treat it like a
    password file: move it with scp (encrypted in transit), and let stage 40 on
    the VPS shred it after unpacking. If `age` is installed the script encrypts
    the bundle with a passphrase you choose; if not, it warns and continues.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\export\export-from-windows.ps1
    scp .\vps-plus-bundle.tar.gz.age rifqi@your.vps.ip:~/

.NOTES
    Close Hermes and Claude Code before running, so no file is mid-write.
#>
[CmdletBinding()]
param(
    [string] $OutFile = "$PSScriptRoot\..\vps-plus-bundle.tar.gz",
    [switch] $IncludeHermesState,
    [switch] $NoEncrypt
)

$ErrorActionPreference = 'Stop'

function Say  ($m) { Write-Host "  $m"   -ForegroundColor DarkGray }
function Step ($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn ($m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Good ($m) { Write-Host " ok $m" -ForegroundColor Green }

$staging = Join-Path $env:TEMP ("vps-plus-bundle-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $staging -Force | Out-Null

# Copy $Source into $staging\$Dest, skipping anything matching $Exclude.
# A missing source is reported, not fatal: a machine without codex still exports.
function Grab {
    param(
        [string]   $Source,
        [string]   $Dest,
        [string[]] $Exclude = @(),
        [switch]   $Required
    )
    if (-not (Test-Path $Source)) {
        if ($Required) { Warn "MISSING (required): $Source" } else { Say "skip (absent): $Source" }
        return
    }
    $target = Join-Path $staging $Dest
    New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null

    if (Test-Path $Source -PathType Leaf) {
        Copy-Item $Source $target -Force
        Say "$Dest"
        return
    }

    # robocopy handles long paths and exclusions far better than Copy-Item, and
    # uses exit codes 0-7 for success. /XJ stops it from following the
    # shared-vault junction inside hermes\skills; the vault ships separately.
    $xd = @()
    foreach ($e in $Exclude) { $xd += @('/XD', $e, '/XF', $e) }
    $null = & robocopy $Source $target /E /NFL /NDL /NJH /NJS /NP /XJ @xd
    if ($LASTEXITCODE -ge 8) { Warn "robocopy issues on $Source (code $LASTEXITCODE)" }
    else { Say "$Dest/" }
    $global:LASTEXITCODE = 0
}

# ---------------------------------------------------------------------------
Step 'Hermes Agent'
# The real config lives in %LOCALAPPDATA%\hermes on native Windows. On Linux the
# same tree is ~/.hermes, so it is staged under that name.
$hermesLocal = Join-Path $env:LOCALAPPDATA 'hermes'

foreach ($f in '.env', 'config.yaml', 'auth.json', 'AGENTS.md', 'SOUL.md',
                'channel_directory.json', 'install_id') {
    Grab (Join-Path $hermesLocal $f) "hermes/$f"
}
Grab (Join-Path $hermesLocal 'memories') 'hermes/memories'
Grab (Join-Path $hermesLocal 'cron')     'hermes/cron'
Grab (Join-Path $hermesLocal 'hooks')    'hermes/hooks'
Grab (Join-Path $hermesLocal 'plugins')  'hermes/plugins'
Grab (Join-Path $hermesLocal 'skills')   'hermes/skills'

# The other Hermes config root, used when Hermes runs under WSL/Git-Bash.
Grab (Join-Path $env:USERPROFILE '.hermes\AGENTS.md') 'hermes/AGENTS.wsl.md'
Grab (Join-Path $env:USERPROFILE '.hermes\.env')      'hermes/.env.wsl'

if ($IncludeHermesState) {
    Warn 'Including state.db (~370 MB). Hermes MUST be closed or the copy will be corrupt.'
    Grab (Join-Path $hermesLocal 'state.db')    'hermes/state.db'
    Grab (Join-Path $hermesLocal 'kanban.db')   'hermes/kanban.db'
    Grab (Join-Path $hermesLocal 'projects.db') 'hermes/projects.db'
} else {
    Say 'state.db skipped (default) - pass -IncludeHermesState to bring session history'
}

# ---------------------------------------------------------------------------
Step 'Claude Code'
$cc = Join-Path $env:USERPROFILE '.claude'
foreach ($f in 'CLAUDE.md', 'RTK.md', 'settings.json', 'settings.local.json',
                '.credentials.json', 'keybindings.json') {
    Grab (Join-Path $cc $f) "claude/$f"
}
Grab (Join-Path $cc 'commands') 'claude/commands'
Grab (Join-Path $cc 'agents')   'claude/agents'
Grab (Join-Path $cc 'skills')   'claude/skills' -Exclude @('node_modules', '.git')
# ~/.claude.json holds the MCP server list and per-project history.
Grab (Join-Path $env:USERPROFILE '.claude.json') 'claude/dot-claude.json'

# ---------------------------------------------------------------------------
Step 'Gemini CLI'
$gm = Join-Path $env:USERPROFILE '.gemini'
Grab (Join-Path $gm 'GEMINI.md')        'gemini/GEMINI.md'
Grab (Join-Path $gm 'settings.json')    'gemini/settings.json'
Grab (Join-Path $gm 'oauth_creds.json') 'gemini/oauth_creds.json'
Grab (Join-Path $gm 'config')           'gemini/config'
Grab (Join-Path $gm 'instructions')     'gemini/instructions'
Grab (Join-Path $gm 'skills')           'gemini/skills'

# ---------------------------------------------------------------------------
Step 'Codex'
$cx = Join-Path $env:USERPROFILE '.codex'
foreach ($f in 'config.toml', 'auth.json', 'AGENTS.md') {
    Grab (Join-Path $cx $f) "codex/$f"
}

# ---------------------------------------------------------------------------
Step 'Skills vault'
# Not a git repo on Windows, so it can only travel as files. Once it is pushed
# to GitHub, set REPO_SKILLS_VAULT in vps.conf and this stops being needed.
Grab 'F:\Claude Work\PROJECTS\AI-Agent-Skills-Vault' 'skills-vault' -Required -Exclude @('.obsidian', 'node_modules', '.git')

# ---------------------------------------------------------------------------
Step 'Application environment files'
# These carry live service-role keys. They are the reason the bundle is secret.
Grab 'E:\PLUSSSSS\plusthesite-\.env'       'appenv/plus.env'
Grab 'E:\PLUSSSSS\studio-plusthesite\.env' 'appenv/studio.env'
Grab 'F:\Trilux Design\.env.local'         'appenv/trilux.env'
Grab 'F:\NEW NALAR\.env.local'             'appenv/nalar.env'

# ---------------------------------------------------------------------------
Step 'Manifest'
$hermesExe = Join-Path $hermesLocal 'bin\hermes.exe'
$hermesVer = ''
if (Test-Path $hermesExe) { $hermesVer = (& $hermesExe --version 2>$null | Select-Object -First 1) }

$manifest = [ordered]@{
    exported_at       = (Get-Date -Format 'o')
    exported_from     = $env:COMPUTERNAME
    includes_state_db = [bool]$IncludeHermesState
    hermes_version    = $hermesVer
}
$manifest | ConvertTo-Json | Set-Content (Join-Path $staging 'MANIFEST.json') -Encoding utf8

# ---------------------------------------------------------------------------
Step 'Packing'
$OutFile = [IO.Path]::GetFullPath($OutFile)
if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
& tar -czf $OutFile -C $staging .
if (-not (Test-Path $OutFile)) { throw "tar failed to produce $OutFile" }

$sizeMB = [math]::Round((Get-Item $OutFile).Length / 1MB, 1)
Good "$OutFile  ($sizeMB MB)"

# ---------------------------------------------------------------------------
$final = $OutFile
if (-not $NoEncrypt) {
    $age = Get-Command age -ErrorAction SilentlyContinue
    if ($age) {
        Step 'Encrypting with age (it will ask for a passphrase twice)'
        & age --passphrase --output "$OutFile.age" $OutFile
        if (Test-Path "$OutFile.age") {
            Remove-Item $OutFile -Force
            $final = "$OutFile.age"
            Good "$final"
        }
    } else {
        Warn 'age is not installed, so the bundle sits on disk in PLAINTEXT.'
        Warn 'Install it with:  winget install FiloSottile.age'
        Warn 'scp is still encrypted in transit - just delete the bundle afterwards.'
    }
}

Remove-Item $staging -Recurse -Force

Write-Host ''
Write-Host 'Next:' -ForegroundColor Cyan
Write-Host "  scp $final <user>@<vps-ip>:~/"
Write-Host '  ssh <user>@<vps-ip>'
Write-Host '  sudo /srv/vps-plus/bootstrap.sh 40-restore-config'
Write-Host ''
Write-Host 'Then delete the local copy - it holds plaintext credentials:' -ForegroundColor Yellow
Write-Host "  Remove-Item $final"
