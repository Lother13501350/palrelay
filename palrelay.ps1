# PalRelay - rotating-host save sync for Palworld dedicated servers.
# Cloud backend: any rclone remote (designed for Google Drive shared folder).
# Spec: docs/DESIGN.md
#
# Requires: Windows PowerShell 5.1+, rclone. Keep this file ASCII-only (PS 5.1
# misreads UTF-8-without-BOM sources that contain non-ASCII characters).

param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'status', 'upload', 'takeover', 'init', 'help')]
    [string]$Command = 'help',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$Script:ToolVersion = '0.1.2'
$Script:ToolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:StateFile = Join-Path $Script:ToolDir 'state.json'
$Script:BackupRoot = Join-Path $Script:ToolDir 'backups'
$Script:Config = $null
$Script:CurrentLock = $null
$Script:SessionVersion = 0

# ---------------------------------------------------------------- output ----

function Write-Info([string]$m) { Write-Host ('[palrelay] ' + $m) -ForegroundColor Cyan }
function Write-Warn([string]$m) { Write-Host ('[palrelay] WARN: ' + $m) -ForegroundColor Yellow }
function Write-Err([string]$m)  { Write-Host ('[palrelay] ERROR: ' + $m) -ForegroundColor Red }

function Confirm-Prompt {
    param([string]$Message, [bool]$DefaultYes)
    $suffix = '[y/N]'
    if ($DefaultYes) { $suffix = '[Y/n]' }
    $ans = Read-Host ($Message + ' ' + $suffix)
    if ($ans -eq '') { return $DefaultYes }
    return ($ans -match '^[Yy]')
}

# ------------------------------------------------------------------ time ----

function Now-Utc   { return [DateTime]::UtcNow }
function Now-Iso   { return [DateTime]::UtcNow.ToString('o') }
function Now-Stamp { return [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') }

function Parse-Utc([string]$s) {
    return [DateTime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind)
}

# ------------------------------------------------------------ config/state --

function Set-DefaultProp($Obj, [string]$Name, $Value) {
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value -or ($p.Value -is [string] -and $p.Value -eq '')) {
        $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Read-Config {
    $path = Join-Path $Script:ToolDir 'config.json'
    if (-not (Test-Path $path)) {
        throw "config.json not found. Run '.\palrelay.ps1 init' and edit the file."
    }
    # Explicit UTF-8: PS 5.1 Get-Content decodes BOM-less files as ANSI, which
    # mangles non-ASCII paths (e.g. a Desktop folder with CJK characters).
    $cfg = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($key in @('playerName', 'remote', 'serverDir')) {
        $p = $cfg.PSObject.Properties[$key]
        if ($null -eq $p -or -not $p.Value) { throw "config.json is missing required field '$key'." }
    }
    Set-DefaultProp $cfg 'rclonePath' 'rclone'
    Set-DefaultProp $cfg 'rcloneConfig' ''
    Set-DefaultProp $cfg 'serverExe' 'PalServer.exe'
    Set-DefaultProp $cfg 'restPort' 8212
    Set-DefaultProp $cfg 'heartbeatMinutes' 5
    Set-DefaultProp $cfg 'staleMinutes' 20
    Set-DefaultProp $cfg 'checkpointMinutes' 0
    Set-DefaultProp $cfg 'keepVersions' 10
    if ($null -eq $cfg.PSObject.Properties['adminPassword']) {
        $cfg | Add-Member -NotePropertyName adminPassword -NotePropertyValue '' -Force
    }
    if ($null -eq $cfg.PSObject.Properties['worldGuid']) {
        $cfg | Add-Member -NotePropertyName worldGuid -NotePropertyValue '' -Force
    }
    if ($null -eq $cfg.PSObject.Properties['serverArgs'] -or $null -eq $cfg.serverArgs) {
        $cfg | Add-Member -NotePropertyName serverArgs -NotePropertyValue @() -Force
    }
    $cfg.remote = ([string]$cfg.remote).TrimEnd('/')
    return $cfg
}

function Read-State {
    if (Test-Path $Script:StateFile) {
        return [IO.File]::ReadAllText($Script:StateFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    return [pscustomobject]@{ phase = 'idle'; lastDownloadedVersion = 0; hostingStartedUtc = '' }
}

function Write-State($State) {
    [IO.File]::WriteAllText($Script:StateFile, ($State | ConvertTo-Json -Depth 5))
}

# ---------------------------------------------------------------- rclone ----

function Get-RcloneArgs([string[]]$Arguments) {
    # Honor an explicit config file (config.json: rcloneConfig) so the tool
    # never depends on the default %APPDATA% location.
    $p = $Script:Config.PSObject.Properties['rcloneConfig']
    if ($null -ne $p -and $p.Value) {
        $cfgPath = [string]$p.Value
        # Relative paths resolve against the tool folder, so config.json can
        # stay free of non-ASCII absolute paths.
        if (-not [IO.Path]::IsPathRooted($cfgPath)) { $cfgPath = Join-Path $Script:ToolDir $cfgPath }
        return (@('--config', $cfgPath) + $Arguments)
    }
    return $Arguments
}

function Invoke-Rclone {
    param([string[]]$Arguments, [switch]$AllowFail)
    $rcArgs = Get-RcloneArgs $Arguments
    # EAP must be Continue around native stderr in PS 5.1, or 2>&1 throws.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $Script:Config.rclonePath @rcArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0 -and -not $AllowFail) {
        $text = ''
        if ($null -ne $out) { $text = (($out | ForEach-Object { $_.ToString() }) -join "`n").Trim() }
        throw ('rclone {0} failed (exit {1}): {2}' -f ($Arguments -join ' '), $code, $text)
    }
    return $code
}

function Invoke-RcloneText {
    # Returns stdout as text, or $null if the command failed (e.g. file missing).
    param([string[]]$Arguments)
    $rcArgs = Get-RcloneArgs $Arguments
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $Script:Config.rclonePath @rcArgs 2>$null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) { return $null }
    if ($null -eq $out) { return '' }
    return (($out | ForEach-Object { $_.ToString() }) -join "`n")
}

function Get-RemotePath([string]$Name) {
    return ($Script:Config.remote + '/' + $Name)
}

function ConvertFrom-JsonArray([string]$Text) {
    # PS 5.1 emits a parsed JSON array as ONE pipeline object, and @(cmd) then
    # wraps it into a single-element array. Normalize to a real element array.
    if ($null -eq $Text -or $Text.Trim() -eq '') { return ,@() }
    $parsed = ConvertFrom-Json -InputObject $Text
    if ($null -eq $parsed) { return ,@() }
    if ($parsed -is [object[]]) { return ,$parsed }
    return ,@($parsed)
}

function Get-RemoteJson([string]$RemotePath) {
    $text = Invoke-RcloneText @('cat', $RemotePath)
    if ($null -eq $text -or $text.Trim() -eq '') { return $null }
    return (ConvertFrom-Json -InputObject $text)
}

function Put-RemoteJson([string]$RemotePath, $Object) {
    $tmp = Join-Path $env:TEMP ('palrelay-' + [guid]::NewGuid().ToString('n') + '.json')
    [IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 5))
    try { Invoke-Rclone @('copyto', $tmp, $RemotePath) | Out-Null }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------ lock ----

function Get-RemoteLock { return Get-RemoteJson (Get-RemotePath 'lock.json') }

function Test-LockOurs($Lock) {
    return ($Lock.holder -eq $Script:Config.playerName -and $Lock.machine -eq $env:COMPUTERNAME)
}

function Test-LockStale($Lock) {
    $age = (Now-Utc) - (Parse-Utc $Lock.heartbeatUtc)
    return ($age.TotalMinutes -gt [double]$Script:Config.staleMinutes)
}

function Acquire-Lock {
    param([switch]$AllowStaleTakeover)
    $existing = Get-RemoteLock
    if ($existing -and -not (Test-LockOurs $existing)) {
        if (-not (Test-LockStale $existing)) {
            throw ('Lock is held by {0} on {1} (started {2} UTC).' -f `
                $existing.holder, $existing.machine, $existing.startedUtc)
        }
        if (-not $AllowStaleTakeover) {
            throw ('Stale lock held by {0} exists; takeover was not confirmed.' -f $existing.holder)
        }
        Write-Warn ('Taking over stale lock from {0}.' -f $existing.holder)
    }
    $lock = [pscustomobject]@{
        holder       = $Script:Config.playerName
        machine      = $env:COMPUTERNAME
        nonce        = [guid]::NewGuid().ToString()
        startedUtc   = (Now-Iso)
        heartbeatUtc = (Now-Iso)
        toolVersion  = $Script:ToolVersion
    }
    Put-RemoteJson (Get-RemotePath 'lock.json') $lock
    Start-Sleep -Seconds 3
    $check = Get-RemoteLock
    if ($null -eq $check -or $check.nonce -ne $lock.nonce) {
        $holder = '(unknown)'
        if ($check) { $holder = $check.holder }
        throw ('Lost the lock race to {0}. Try again in a moment.' -f $holder)
    }
    $Script:CurrentLock = $lock
    return $lock
}

function Update-LockHeartbeat {
    if ($null -eq $Script:CurrentLock) { return }
    $current = Get-RemoteLock
    if ($null -eq $current -or $current.nonce -ne $Script:CurrentLock.nonce) {
        Write-Warn 'LOCK CONFLICT: the remote lock is no longer ours! Someone may have taken over.'
        Write-Warn 'Coordinate with your group NOW - two hosts at once will fork the save.'
        return
    }
    $Script:CurrentLock.heartbeatUtc = (Now-Iso)
    Put-RemoteJson (Get-RemotePath 'lock.json') $Script:CurrentLock
}

function Release-Lock($Lock) {
    $current = Get-RemoteLock
    if ($null -eq $current) { return }
    if ($Lock -and $current.nonce -ne $Lock.nonce) {
        Write-Warn 'Remote lock is not ours anymore; leaving it in place.'
        return
    }
    Invoke-Rclone @('deletefile', (Get-RemotePath 'lock.json')) -AllowFail | Out-Null
}

# ------------------------------------------------------------- save files ---

function Get-SaveRoot { return (Join-Path $Script:Config.serverDir 'Pal\Saved\SaveGames\0') }

function Resolve-WorldGuid($Latest) {
    if ($Latest -and $Latest.worldGuid) { return [string]$Latest.worldGuid }
    if ($Script:Config.worldGuid) { return [string]$Script:Config.worldGuid }
    $saveRoot = Get-SaveRoot
    # GameUserSettings.ini records which world the server actually loads; it is
    # the authoritative pick when several world folders exist.
    $gus = Join-Path $Script:Config.serverDir 'Pal\Saved\Config\WindowsServer\GameUserSettings.ini'
    if (Test-Path $gus) {
        $c = Get-Content -Raw -Path $gus
        if ($c -match 'DedicatedServerName=([0-9A-Fa-f]{32})') {
            $g = $Matches[1]
            if (Test-Path (Join-Path $saveRoot $g)) { return $g }
        }
    }
    if (-not (Test-Path $saveRoot)) { return $null }
    $dirs = @(Get-ChildItem -Path $saveRoot -Directory)
    if ($dirs.Count -eq 1) { return $dirs[0].Name }
    if ($dirs.Count -gt 1) {
        Write-Warn ('Multiple world folders under {0}; set "worldGuid" in config.json.' -f $saveRoot)
    }
    return $null
}

function Prune-LocalBackups {
    if (-not (Test-Path $Script:BackupRoot)) { return }
    Get-ChildItem -Path $Script:BackupRoot -Directory |
        Sort-Object Name -Descending |
        Select-Object -Skip 3 |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Sync-Down($Latest) {
    if ($null -eq $Latest) {
        Write-Info 'Remote has no save yet; starting from local state.'
        return
    }
    if (-not $Latest.worldGuid) { throw 'latest.json has no worldGuid; remote data looks corrupt.' }
    $state = Read-State
    $saveRoot = Get-SaveRoot
    $target = Join-Path $saveRoot $Latest.worldGuid
    if (([int]$Latest.version -eq [int]$state.lastDownloadedVersion) -and (Test-Path $target)) {
        Write-Info ('Local save already at v{0}; skipping download.' -f $Latest.version)
        return
    }
    $tmpZip = Join-Path $env:TEMP ('palrelay-dl-' + [guid]::NewGuid().ToString('n') + '.zip')
    Write-Info ('Downloading save v{0} ({1})...' -f $Latest.version, $Latest.zip)
    Invoke-Rclone @('copyto', (Get-RemotePath ('saves/' + $Latest.zip)), $tmpZip) | Out-Null
    try {
        $hash = (Get-FileHash -Path $tmpZip -Algorithm SHA256).Hash
        if ($hash -ne $Latest.sha256) {
            throw 'Downloaded zip failed SHA-256 verification; aborting (local save untouched).'
        }
        if (Test-Path $target) {
            if (-not (Test-Path $Script:BackupRoot)) {
                New-Item -ItemType Directory -Path $Script:BackupRoot -Force | Out-Null
            }
            $bk = Join-Path $Script:BackupRoot ($Latest.worldGuid + '-' + (Now-Stamp))
            Move-Item -Path $target -Destination $bk
            Prune-LocalBackups
        }
        if (-not (Test-Path $saveRoot)) {
            New-Item -ItemType Directory -Path $saveRoot -Force | Out-Null
        }
        Expand-Archive -Path $tmpZip -DestinationPath $saveRoot -Force
    } finally {
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
    }
    $state.lastDownloadedVersion = [int]$Latest.version
    Write-State $state
    Write-Info ('Save v{0} ready.' -f $Latest.version)
}

function Prune-RemoteSaves {
    param([string]$KeepZip)
    $keep = [int]$Script:Config.keepVersions
    $text = Invoke-RcloneText @('lsjson', (Get-RemotePath 'saves'))
    if ($null -eq $text -or $text.Trim() -eq '') { return }
    $all = ConvertFrom-JsonArray $text
    $items = @($all | Where-Object { $_.Name -match '^world-v(\d+)-.*\.zip$' })
    $sorted = $items | Sort-Object {
        [int][regex]::Match($_.Name, '^world-v(\d+)-').Groups[1].Value
    } -Descending
    $extra = @($sorted | Select-Object -Skip $keep | Where-Object { $_.Name -ne $KeepZip })
    foreach ($it in $extra) {
        Write-Info ('Pruning old save {0}' -f $it.Name)
        Invoke-Rclone @('deletefile', (Get-RemotePath ('saves/' + $it.Name))) -AllowFail | Out-Null
    }
}

function Publish-Save {
    param([string]$SourceDir, [string]$WorldGuid, [int]$NewVersion)
    $cfg = $Script:Config
    $SourceDir = $SourceDir.TrimEnd('\')
    if (-not (Test-Path $SourceDir)) { throw ('Save folder not found: {0}' -f $SourceDir) }
    $safeName = ($cfg.playerName -replace '[^A-Za-z0-9_\-]', '')
    if (-not $safeName) { $safeName = 'player' }
    $zipName = ('world-v{0:d4}-{1}-{2}.zip' -f $NewVersion, (Now-Stamp), $safeName)
    $tmpZip = Join-Path $env:TEMP $zipName
    if (Test-Path $tmpZip) { Remove-Item $tmpZip -Force }
    Write-Info ('Packing save (v{0})...' -f $NewVersion)
    Compress-Archive -Path $SourceDir -DestinationPath $tmpZip -CompressionLevel Optimal
    try {
        $hash = (Get-FileHash -Path $tmpZip -Algorithm SHA256).Hash
        $size = (Get-Item $tmpZip).Length
        Write-Info ('Uploading {0} ({1:n1} MB)...' -f $zipName, ($size / 1MB))
        Invoke-Rclone @('copyto', $tmpZip, (Get-RemotePath ('saves/' + $zipName))) | Out-Null
        $listing = Invoke-RcloneText @('lsjson', (Get-RemotePath ('saves/' + $zipName)))
        $entries = ConvertFrom-JsonArray $listing
        $entry = $null
        if ($entries.Count -gt 0) { $entry = $entries[0] }
        if ($null -eq $entry -or [int64]$entry.Size -ne $size) {
            throw 'Upload verification failed (remote file missing or size mismatch).'
        }
        $latest = [pscustomobject]@{
            version     = $NewVersion
            zip         = $zipName
            sha256      = $hash
            sizeBytes   = $size
            worldGuid   = $WorldGuid
            uploadedBy  = $cfg.playerName
            uploadedUtc = (Now-Iso)
            toolVersion = $Script:ToolVersion
        }
        Put-RemoteJson (Get-RemotePath 'latest.json') $latest
        Prune-RemoteSaves -KeepZip $zipName
        $Script:SessionVersion = $NewVersion
        return $latest
    } finally {
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------- server ctl ---

function Test-Prereqs {
    $cfg = $Script:Config
    try { $null = Get-Command $cfg.rclonePath -ErrorAction Stop }
    catch { throw ('rclone not found at "{0}". Install it or set rclonePath in config.json.' -f $cfg.rclonePath) }
    if (-not (Test-Path $cfg.serverDir)) { throw ('serverDir not found: {0}' -f $cfg.serverDir) }
    $exe = Join-Path $cfg.serverDir $cfg.serverExe
    if (-not (Test-Path $exe)) { throw ('Server executable not found: {0}' -f $exe) }
    Ensure-ServerSettings
}

function Ensure-ServerSettings {
    # Self-provisions PalWorldSettings.ini (REST API on, admin password from
    # config.json) so graceful shutdown always works. Running inside the host
    # user's own session guarantees the file is visible to the server process.
    $cfg = $Script:Config
    if (-not $cfg.adminPassword) {
        Write-Warn 'adminPassword is empty in config.json - REST shutdown will not work.'
        return
    }
    $iniDir = Join-Path $cfg.serverDir 'Pal\Saved\Config\WindowsServer'
    $ini = Join-Path $iniDir 'PalWorldSettings.ini'
    $base = ''
    if (Test-Path $ini) { $base = Get-Content -Raw -Path $ini }
    $wantPw = 'AdminPassword="' + $cfg.adminPassword + '"'
    $wantPort = 'RESTAPIPort=' + $cfg.restPort
    if ($base.Contains('RESTAPIEnabled=True') -and $base.Contains($wantPw) -and $base.Contains($wantPort)) {
        return
    }
    if ($base -notmatch 'OptionSettings=\(') {
        $default = Join-Path $cfg.serverDir 'DefaultPalWorldSettings.ini'
        if (-not (Test-Path $default)) {
            Write-Warn 'No usable PalWorldSettings.ini and no DefaultPalWorldSettings.ini; cannot configure the REST API.'
            return
        }
        $base = Get-Content -Raw -Path $default
    }
    $base = [regex]::Replace($base, 'AdminPassword="[^"]*"', $wantPw)
    $base = [regex]::Replace($base, 'RESTAPIEnabled=(True|False)', 'RESTAPIEnabled=True')
    $base = [regex]::Replace($base, 'RESTAPIPort=\d+', $wantPort)
    if (-not (Test-Path $iniDir)) { New-Item -ItemType Directory -Path $iniDir -Force | Out-Null }
    [IO.File]::WriteAllText($ini, $base)
    Write-Info 'PalWorldSettings.ini configured (REST API enabled, admin password applied).'
}

function Ensure-DedicatedServerName([string]$WorldGuid) {
    $ini = Join-Path $Script:Config.serverDir 'Pal\Saved\Config\WindowsServer\GameUserSettings.ini'
    if (-not (Test-Path $ini)) {
        Write-Warn 'GameUserSettings.ini not found; the server may create a fresh world. Launch once first if this is unexpected.'
        return
    }
    $content = Get-Content -Raw -Path $ini
    if ($content -match 'DedicatedServerName=([^\r\n]+)') {
        $current = $Matches[1].Trim()
        if ($current -ne $WorldGuid) {
            $content = $content -replace 'DedicatedServerName=[^\r\n]*', ('DedicatedServerName=' + $WorldGuid)
            [IO.File]::WriteAllText($ini, $content)
            Write-Info ('GameUserSettings.ini: DedicatedServerName {0} -> {1}' -f $current, $WorldGuid)
        }
    } else {
        Write-Warn 'DedicatedServerName not found in GameUserSettings.ini; server may not load the synced world.'
    }
}

function Invoke-ServerApi {
    param([string]$Method, [string]$Endpoint, $BodyObj)
    $cfg = $Script:Config
    $auth = 'Basic ' + [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes('admin:' + $cfg.adminPassword))
    $params = @{
        Method     = $Method
        Uri        = ('http://127.0.0.1:{0}/v1/api/{1}' -f $cfg.restPort, $Endpoint)
        Headers    = @{ Authorization = $auth }
        TimeoutSec = 10
    }
    if ($null -ne $BodyObj) {
        $params.Body = ($BodyObj | ConvertTo-Json -Compress)
        $params.ContentType = 'application/json'
    }
    return Invoke-RestMethod @params
}

function Start-Server {
    $cfg = $Script:Config
    $exe = Join-Path $cfg.serverDir $cfg.serverExe
    $procArgs = @($cfg.serverArgs)
    if ($procArgs.Count -gt 0) {
        return Start-Process -FilePath $exe -ArgumentList $procArgs -WorkingDirectory $cfg.serverDir -PassThru
    }
    return Start-Process -FilePath $exe -WorkingDirectory $cfg.serverDir -PassThru
}

function Test-ServerAlive($Proc) {
    if ($Proc -and -not $Proc.HasExited) { return $true }
    $p = Get-Process -Name 'PalServer*' -ErrorAction SilentlyContinue | Select-Object -First 1
    return ($null -ne $p)
}

function Stop-ServerGraceful($Proc) {
    if (-not (Test-ServerAlive $Proc)) { return $true }
    Write-Info 'Requesting server save + shutdown via REST API...'
    try {
        Invoke-ServerApi 'POST' 'save' $null | Out-Null
        Invoke-ServerApi 'POST' 'shutdown' @{ waittime = 10; message = 'Server closing (PalRelay).' } | Out-Null
    } catch {
        Write-Warn ('REST shutdown failed: {0}' -f $_.Exception.Message)
    }
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-ServerAlive $Proc)) { return $true }
        Start-Sleep -Seconds 2
    }
    Write-Warn 'Server did not exit in 90s; force-killing (last autosave may be slightly stale).'
    Get-Process -Name 'PalServer*' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
    return $false
}

function Invoke-Checkpoint {
    $guid = Resolve-WorldGuid $null
    if (-not $guid) { return }
    Write-Info 'Checkpoint: asking server to save...'
    try {
        Invoke-ServerApi 'POST' 'save' $null | Out-Null
        Start-Sleep -Seconds 5
    } catch {
        Write-Warn 'Checkpoint REST save failed; snapshotting current files anyway.'
    }
    $stage = Join-Path $env:TEMP ('palrelay-cp-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        Copy-Item -Path (Join-Path (Get-SaveRoot) $guid) -Destination $stage -Recurse
        $newVersion = $Script:SessionVersion + 1
        Publish-Save -SourceDir (Join-Path $stage $guid) -WorldGuid $guid -NewVersion $newVersion | Out-Null
        Write-Info ('Checkpoint uploaded as v{0}.' -f $newVersion)
    } finally {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Wait-Session($Proc) {
    $cfg = $Script:Config
    $lastHb = [DateTime]::UtcNow
    $lastCp = [DateTime]::UtcNow
    $keySupported = $true
    try { $null = [Console]::KeyAvailable }
    catch {
        $keySupported = $false
        Write-Warn 'No interactive console; stop with Ctrl+C and run ".\palrelay.ps1 upload" afterwards.'
    }
    while ($true) {
        if (-not (Test-ServerAlive $Proc)) { return $false }
        if ($keySupported -and [Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq [ConsoleKey]::Q) { return $true }
        }
        if (([DateTime]::UtcNow - $lastHb).TotalMinutes -ge [double]$cfg.heartbeatMinutes) {
            try { Update-LockHeartbeat } catch { Write-Warn ('Heartbeat failed: {0}' -f $_.Exception.Message) }
            $lastHb = [DateTime]::UtcNow
        }
        if ([double]$cfg.checkpointMinutes -gt 0 -and
            ([DateTime]::UtcNow - $lastCp).TotalMinutes -ge [double]$cfg.checkpointMinutes) {
            try { Invoke-Checkpoint } catch { Write-Warn ('Checkpoint failed: {0}' -f $_.Exception.Message) }
            $lastCp = [DateTime]::UtcNow
        }
        Start-Sleep -Seconds 2
    }
}

# -------------------------------------------------------------- commands ----

function Cmd-Start {
    Test-Prereqs
    $state = Read-State
    if ($state.phase -eq 'hosting') {
        Write-Warn 'Previous session did not finish uploading (crash or interrupted?).'
        if (Confirm-Prompt 'Upload the local save now before starting a new session?' $true) {
            $code = Cmd-Upload
            if ($code -ne 0) { return $code }
        } else {
            Write-Warn 'Continuing WITHOUT uploading; remote may overwrite your local progress.'
            $state.phase = 'idle'
            Write-State $state
        }
        $state = Read-State
    }

    $lock = Get-RemoteLock
    $staleTakeover = $false
    if ($lock -and -not (Test-LockOurs $lock)) {
        if (-not (Test-LockStale $lock)) {
            Write-Err ('World is being hosted by {0} on {1} (started {2} UTC, heartbeat {3} UTC).' -f `
                $lock.holder, $lock.machine, $lock.startedUtc, $lock.heartbeatUtc)
            return 2
        }
        Write-Warn ('Found a STALE lock from {0} (last heartbeat {1} UTC).' -f $lock.holder, $lock.heartbeatUtc)
        Write-Warn 'Taking over means any progress they did not upload is lost.'
        if (-not ($Force -or (Confirm-Prompt 'Take over the stale lock?' $false))) { return 2 }
        $staleTakeover = $true
    }

    if ($staleTakeover) { $myLock = Acquire-Lock -AllowStaleTakeover } else { $myLock = Acquire-Lock }
    Write-Info ('Lock acquired by {0}.' -f $myLock.holder)

    $published = $false
    $serverStarted = $false
    try {
        $latest = Get-RemoteJson (Get-RemotePath 'latest.json')
        Sync-Down $latest
        $guid = Resolve-WorldGuid $latest
        if ($guid) { Ensure-DedicatedServerName $guid }
        else { Write-Warn 'No existing world found - the server will create a new one on first launch.' }

        $baseVersion = 0
        if ($latest) { $baseVersion = [int]$latest.version }
        $Script:SessionVersion = $baseVersion

        $state = Read-State
        $state.phase = 'hosting'
        $state.hostingStartedUtc = (Now-Iso)
        Write-State $state

        $proc = Start-Server
        $serverStarted = $true
        Write-Host ''
        Write-Info 'Server starting. Friends can join once it is up (UDP 8211 / your Tailscale IP).'
        Write-Info 'Press [Q] in this window to stop the server and upload the save.'
        Write-Host ''

        $stopRequested = Wait-Session $proc
        if ($stopRequested) {
            Stop-ServerGraceful $proc | Out-Null
        } else {
            Write-Warn 'Server process exited on its own.'
            if (-not (Confirm-Prompt 'Upload the current local save anyway?' $true)) {
                Write-Warn 'Save NOT uploaded and lock kept. Run ".\palrelay.ps1 upload" when ready.'
                return 5
            }
        }

        if (-not $guid) { $guid = Resolve-WorldGuid $null }
        if (-not $guid) {
            throw 'Could not find the world folder under SaveGames\0. Set "worldGuid" in config.json, then run ".\palrelay.ps1 upload".'
        }
        $newVersion = $Script:SessionVersion + 1
        Publish-Save -SourceDir (Join-Path (Get-SaveRoot) $guid) -WorldGuid $guid -NewVersion $newVersion | Out-Null

        $state = Read-State
        $state.phase = 'idle'
        $state.lastDownloadedVersion = $newVersion
        $state.hostingStartedUtc = ''
        Write-State $state
        $published = $true
        Write-Info ('Uploaded save v{0}. Session complete - the world is free for the next host.' -f $newVersion)
        return 0
    } finally {
        if ($published) {
            Release-Lock $myLock
        } elseif (-not $serverStarted) {
            # Nothing changed locally; safe to free the world.
            Release-Lock $myLock
        } else {
            Write-Warn 'Lock NOT released because the save was not uploaded.'
            Write-Warn 'Fix the problem and run ".\palrelay.ps1 upload" - it will release the lock on success.'
        }
    }
}

function Cmd-Upload {
    $lock = Get-RemoteLock
    if ($lock -and -not (Test-LockOurs $lock) -and -not (Test-LockStale $lock) -and -not $Force) {
        Write-Err ('Cannot upload: {0} currently holds the lock (hosting). Use -Force only if you are certain.' -f $lock.holder)
        return 2
    }
    $latest = Get-RemoteJson (Get-RemotePath 'latest.json')
    $guid = Resolve-WorldGuid $latest
    if (-not $guid) {
        Write-Err 'No world folder found under SaveGames\0 and no worldGuid configured.'
        return 3
    }
    $base = 0
    if ($latest) { $base = [int]$latest.version }
    $newVersion = $base + 1
    Publish-Save -SourceDir (Join-Path (Get-SaveRoot) $guid) -WorldGuid $guid -NewVersion $newVersion | Out-Null

    $state = Read-State
    $state.phase = 'idle'
    $state.lastDownloadedVersion = $newVersion
    $state.hostingStartedUtc = ''
    Write-State $state

    if ($lock -and (Test-LockOurs $lock)) { Release-Lock $lock }
    Write-Info ('Uploaded save v{0}.' -f $newVersion)
    return 0
}

function Cmd-Status {
    $lock = Get-RemoteLock
    $latest = Get-RemoteJson (Get-RemotePath 'latest.json')
    $state = Read-State
    Write-Host '--- PalRelay status ---'
    if ($lock) {
        $staleTag = ''
        if (Test-LockStale $lock) { $staleTag = '  [STALE - takeover possible]' }
        Write-Host ('Hosting now : {0} on {1} (started {2} UTC, heartbeat {3} UTC){4}' -f `
            $lock.holder, $lock.machine, $lock.startedUtc, $lock.heartbeatUtc, $staleTag)
    } else {
        Write-Host 'Hosting now : nobody (world is free)'
    }
    if ($latest) {
        $mb = 0.0
        if ($latest.PSObject.Properties['sizeBytes']) { $mb = [double]$latest.sizeBytes / 1MB }
        Write-Host ('Latest save : v{0} by {1} at {2} UTC ({3:n1} MB)' -f `
            $latest.version, $latest.uploadedBy, $latest.uploadedUtc, $mb)
    } else {
        Write-Host 'Latest save : none uploaded yet'
    }
    Write-Host ('Local state : phase={0}, lastDownloadedVersion={1}' -f $state.phase, $state.lastDownloadedVersion)
    return 0
}

function Cmd-Takeover {
    $lock = Get-RemoteLock
    if ($null -eq $lock) {
        Write-Info 'No lock present; nothing to take over.'
        return 0
    }
    if (Test-LockOurs $lock) {
        Write-Info 'The lock is ours; releasing it.'
        Release-Lock $lock
        return 0
    }
    if (-not (Test-LockStale $lock) -and -not $Force) {
        Write-Err ('Lock held by {0} and still fresh (heartbeat {1} UTC). Refusing.' -f $lock.holder, $lock.heartbeatUtc)
        Write-Err 'Use -Force ONLY after confirming with them directly.'
        return 2
    }
    Write-Warn ('Removing lock held by {0}. Progress they did not upload will be lost.' -f $lock.holder)
    if (-not ($Force -or (Confirm-Prompt 'Proceed?' $false))) { return 2 }
    Invoke-Rclone @('deletefile', (Get-RemotePath 'lock.json')) | Out-Null
    Write-Info 'Lock removed.'
    return 0
}

function Cmd-Init {
    $dst = Join-Path $Script:ToolDir 'config.json'
    if (Test-Path $dst) {
        Write-Info 'config.json already exists; nothing to do.'
        return 0
    }
    Copy-Item (Join-Path $Script:ToolDir 'config.sample.json') $dst
    Write-Info 'Created config.json - edit playerName, remote, serverDir and adminPassword.'
    return 0
}

function Show-Help {
    Write-Host @"
PalRelay v$($Script:ToolVersion) - rotating-host save sync for Palworld dedicated servers

Usage: .\palrelay.ps1 <command> [-Force]

Commands:
  start     Acquire the lock, sync the latest save, run the server; press Q
            to stop, upload and release the lock.
  status    Show who is hosting and the latest uploaded save version.
  upload    Upload the local save manually (crash recovery / first seed).
  takeover  Remove a stale lock left behind by a crashed host.
  init      Create config.json from config.sample.json.
  help      Show this help.

Docs: README.md (setup) / docs/DESIGN.md (protocol spec)
"@
    return 0
}

function Main {
    param([string]$Cmd)
    if ($Cmd -eq 'help') { $null = Show-Help; exit 0 }
    if ($Cmd -eq 'init') { exit (Cmd-Init) }
    try {
        $Script:Config = Read-Config
    } catch {
        Write-Err $_.Exception.Message
        exit 3
    }
    $code = 1
    try {
        switch ($Cmd) {
            'start'    { $code = Cmd-Start }
            'status'   { $code = Cmd-Status }
            'upload'   { $code = Cmd-Upload }
            'takeover' { $code = Cmd-Takeover }
        }
    } catch {
        Write-Err $_.Exception.Message
        $code = 1
    }
    exit $code
}

if ($env:PALRELAY_TEST -ne '1') {
    Main -Cmd $Command
}
