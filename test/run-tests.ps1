# PalRelay offline test harness.
# Dot-sources palrelay.ps1 (PALRELAY_TEST=1 skips Main) and exercises the lock
# protocol and sync/publish/prune logic against fake-rclone + a temp folder.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$env:PALRELAY_TEST = '1'
. (Join-Path $here '..\palrelay.ps1')

# --- workspace under %TEMP% (ASCII path; avoids console codepage quirks) ----
$work = Join-Path $env:TEMP ('palrelay-test-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $work | Out-Null
$remoteRoot = Join-Path $work 'remote'
New-Item -ItemType Directory -Path $remoteRoot | Out-Null
$env:FAKE_RCLONE_ROOT = $remoteRoot
Copy-Item (Join-Path $here 'fake-rclone.ps1') $work
Copy-Item (Join-Path $here 'fake-rclone.cmd') $work

# --- fabricate a server save layout ----------------------------------------
$guid = 'ABCDEF0123456789ABCDEF0123456789'
$serverDir1 = Join-Path $work 'PalServer1'
$serverDir2 = Join-Path $work 'PalServer2'
$serverDir3 = Join-Path $work 'PalServer3'
$saveRoot1 = Join-Path $serverDir1 'Pal\Saved\SaveGames\0'
$saveRoot2 = Join-Path $serverDir2 'Pal\Saved\SaveGames\0'
New-Item -ItemType Directory -Path (Join-Path $saveRoot1 "$guid\Players") -Force | Out-Null
Set-Content -Path (Join-Path $saveRoot1 "$guid\Level.sav") -Value 'dummy-level-data-v1'
Set-Content -Path (Join-Path $saveRoot1 "$guid\Players\p1.sav") -Value 'dummy-player-data'

$Script:Config = [pscustomobject]@{
    playerName        = 'tester'
    remote            = 'fake:'
    serverDir         = $serverDir1
    rclonePath        = (Join-Path $work 'fake-rclone.cmd')
    serverExe         = 'PalServer.exe'
    serverArgs        = @()
    adminPassword     = 'x'
    restPort          = 8212
    heartbeatMinutes  = 5
    staleMinutes      = 20
    checkpointMinutes = 0
    keepVersions      = 3
    worldGuid         = ''
}
$Script:Config.remote = $Script:Config.remote.TrimEnd('/')
$Script:StateFile = Join-Path $work 'state.json'
$Script:BackupRoot = Join-Path $work 'backups'

# --- tiny assertion helpers -------------------------------------------------
$script:PassCount = 0
$script:FailCount = 0
function Assert([bool]$Cond, [string]$Name) {
    if ($Cond) { $script:PassCount++; Write-Host ('  PASS  ' + $Name) -ForegroundColor Green }
    else       { $script:FailCount++; Write-Host ('  FAIL  ' + $Name) -ForegroundColor Red }
}
function Assert-Throws([scriptblock]$Block, [string]$Name) {
    $threw = $false
    try { & $Block | Out-Null } catch { $threw = $true }
    Assert $threw $Name
}

Write-Host "Workspace: $work"
Write-Host ''

# T1: empty remote ------------------------------------------------------------
Assert ($null -eq (Get-RemoteLock)) 'empty remote: no lock'
Assert ($null -eq (Get-RemoteJson (Get-RemotePath 'latest.json'))) 'empty remote: no latest'

# T2: acquire lock ------------------------------------------------------------
# NB: variable names here must not collide with the tool's $Script:* variables
# (dot-sourcing shares the scope, and PS names are case-insensitive).
$lockA = Acquire-Lock
$remoteLock = Get-RemoteLock
Assert ($null -ne $remoteLock -and $remoteLock.holder -eq 'tester') 'acquire-lock writes our lock'
Assert ($remoteLock.nonce -eq $lockA.nonce) 'acquire-lock nonce verified'

# T3: re-acquire our own (fresh) lock is allowed ------------------------------
$lockB = Acquire-Lock
Assert ($lockB.nonce -ne $lockA.nonce) 're-acquiring own lock issues new nonce'

# T4: fresh foreign lock is refused -------------------------------------------
$bob = [pscustomobject]@{
    holder = 'bob'; machine = 'BOBPC'; nonce = [guid]::NewGuid().ToString()
    startedUtc = (Now-Iso); heartbeatUtc = (Now-Iso); toolVersion = '0.1.0'
}
Put-RemoteJson (Get-RemotePath 'lock.json') $bob
Assert (-not (Test-LockStale (Get-RemoteLock))) 'fresh foreign lock is not stale'
Assert-Throws { Acquire-Lock } 'acquire refuses fresh foreign lock'

# T5: stale foreign lock ------------------------------------------------------
$bob.heartbeatUtc = [DateTime]::UtcNow.AddMinutes(-60).ToString('o')
Put-RemoteJson (Get-RemotePath 'lock.json') $bob
Assert (Test-LockStale (Get-RemoteLock)) 'old heartbeat marks lock stale'
Assert-Throws { Acquire-Lock } 'stale takeover still needs explicit confirmation'
$lockC = Acquire-Lock -AllowStaleTakeover
Assert ((Get-RemoteLock).holder -eq 'tester') 'stale lock takeover succeeds when confirmed'

# T6: release ----------------------------------------------------------------
Release-Lock $lockC
Assert ($null -eq (Get-RemoteLock)) 'release-lock removes the lock'

# T7: first seed via Cmd-Upload ----------------------------------------------
$code = Cmd-Upload
$latest = Get-RemoteJson (Get-RemotePath 'latest.json')
Assert ($code -eq 0) 'seed upload returns 0'
Assert ($null -ne $latest -and [int]$latest.version -eq 1) 'seed upload creates latest v1'
Assert ($latest.worldGuid -eq $guid) 'latest records world guid'
$zips = ConvertFrom-JsonArray (Invoke-RcloneText @('lsjson', (Get-RemotePath 'saves')))
Assert ($zips.Count -eq 1) 'one zip in saves after seed'
Assert ([int](Read-State).lastDownloadedVersion -eq 1) 'state tracks uploaded version'

# T8: sync-down onto a second machine ----------------------------------------
$Script:Config.serverDir = $serverDir2
Write-State ([pscustomobject]@{ phase = 'idle'; lastDownloadedVersion = 0; hostingStartedUtc = '' })
$latest = Get-RemoteJson (Get-RemotePath 'latest.json')
Sync-Down $latest
$srcLevel = Get-Content -Raw (Join-Path $saveRoot1 "$guid\Level.sav")
$dstLevel = Get-Content -Raw (Join-Path $saveRoot2 "$guid\Level.sav")
Assert ($srcLevel -eq $dstLevel) 'sync-down restores identical Level.sav'
Assert (Test-Path (Join-Path $saveRoot2 "$guid\Players\p1.sav")) 'sync-down restores player files'
Assert ([int](Read-State).lastDownloadedVersion -eq 1) 'sync-down updates state version'

# T9: versioning + pruning (keepVersions = 3) --------------------------------
for ($i = 2; $i -le 5; $i++) {
    Set-Content -Path (Join-Path $saveRoot2 "$guid\Level.sav") -Value ('dummy-level-data-v' + $i)
    $code = Cmd-Upload
    if ($code -ne 0) { Assert $false ('upload v' + $i + ' returns 0') }
}
$latest = Get-RemoteJson (Get-RemotePath 'latest.json')
Assert ([int]$latest.version -eq 5) 'latest advances to v5'
$zips = ConvertFrom-JsonArray (Invoke-RcloneText @('lsjson', (Get-RemotePath 'saves')))
Assert ($zips.Count -eq 3) 'prune keeps only 3 zips'
$names = @($zips | ForEach-Object { $_.Name })
Assert (($names -match '^world-v0005-').Count -eq 1) 'newest zip retained'
Assert (($names -match '^world-v0002-').Count -eq 0) 'oldest zip pruned'

# T10: corrupted download is rejected -----------------------------------------
$Script:Config.serverDir = $serverDir3
Write-State ([pscustomobject]@{ phase = 'idle'; lastDownloadedVersion = 0; hostingStartedUtc = '' })
$badLatest = Get-RemoteJson (Get-RemotePath 'latest.json')
$badLatest.sha256 = 'DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF'
Assert-Throws { Sync-Down $badLatest } 'hash mismatch aborts sync-down'
Assert (-not (Test-Path (Join-Path $serverDir3 "Pal\Saved\SaveGames\0\$guid"))) 'corrupt download leaves no partial save'

# --- summary -----------------------------------------------------------------
Write-Host ''
Write-Host ('Results: {0} passed, {1} failed' -f $script:PassCount, $script:FailCount)
$env:PALRELAY_TEST = ''
Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
exit $script:FailCount
