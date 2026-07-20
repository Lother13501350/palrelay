# PalRelay offline test harness.
# Dot-sources palrelay.ps1 (PALRELAY_TEST=1 skips Main) and exercises the lock
# protocol, sync/publish/prune logic, multi-world layout and v1->v2 migration
# against fake-rclone + a temp folder.

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
# The server's own backup folder must NOT end up inside uploaded zips.
New-Item -ItemType Directory -Path (Join-Path $saveRoot1 "$guid\backup") -Force | Out-Null
Set-Content -Path (Join-Path $saveRoot1 "$guid\backup\old.sav") -Value 'bulky-server-side-backup'

$Script:Config = [pscustomobject]@{
    playerName        = 'tester'
    remote            = 'fake:'
    serverDir         = $serverDir1
    rclonePath        = (Join-Path $work 'fake-rclone.cmd')
    rcloneConfig      = ''
    serverExe         = 'PalServer.exe'
    serverPort        = 8211
    serverArgs        = @()
    adminPassword     = 'group-pw-123'
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
$Script:WorldName = 'main'

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

# T0: v1 -> v2 cloud migration ------------------------------------------------
# Seed a legacy flat layout, then Ensure-CloudLayout must move it to worlds/main
# and bootstrap group.json from config.adminPassword.
$legacyLatest = [pscustomobject]@{ version = 7; zip = 'world-v0007-legacy-tester.zip'; sha256 = 'X'; sizeBytes = 1; worldGuid = $guid; uploadedBy = 'tester'; uploadedUtc = (Now-Iso); toolVersion = '0.1.2' }
Put-RemoteJson (Get-RemotePath 'latest.json') $legacyLatest
New-Item -ItemType Directory -Path (Join-Path $remoteRoot 'saves') -Force | Out-Null
Set-Content -Path (Join-Path $remoteRoot 'saves\world-v0007-legacy-tester.zip') -Value 'legacy-zip-bytes'
Ensure-CloudLayout
Assert ($null -eq (Get-RemoteJson (Get-RemotePath 'latest.json'))) 'migration removes root latest.json'
$migrated = Get-RemoteJson (Get-WorldPath 'latest.json')
Assert ($null -ne $migrated -and [int]$migrated.version -eq 7) 'migration moves latest.json into worlds/main'
Assert (Test-Path (Join-Path $remoteRoot 'worlds\main\saves\world-v0007-legacy-tester.zip')) 'migration moves saves folder'
$group = Get-RemoteJson (Get-RemotePath 'group.json')
Assert ($null -ne $group -and $group.adminPassword -eq 'group-pw-123') 'group.json bootstrapped from config'
Assert ((Get-AdminPassword) -eq 'group-pw-123') 'admin password resolves via group.json'
# v1 local state migration
Set-Content -Path $Script:StateFile -Value '{"phase":"idle","lastDownloadedVersion":7,"hostingStartedUtc":""}'
Assert ([int](Read-WorldState).lastDownloadedVersion -eq 7) 'v1 state.json migrates to worlds.main'
# reset remote world + local state for the clean-slate tests below
Remove-Item (Join-Path $remoteRoot 'worlds') -Recurse -Force
Remove-Item $Script:StateFile -Force

# T1: empty world -------------------------------------------------------------
Assert ($null -eq (Get-RemoteLock)) 'empty world: no lock'
Assert ($null -eq (Get-RemoteJson (Get-WorldPath 'latest.json'))) 'empty world: no latest'

# T2: acquire lock ------------------------------------------------------------
# NB: variable names here must not collide with the tool's $Script:* variables
# (dot-sourcing shares the scope, and PS names are case-insensitive).
$lockA = Acquire-Lock
$remoteLock = Get-RemoteLock
Assert ($null -ne $remoteLock -and $remoteLock.holder -eq 'tester') 'acquire-lock writes our lock'
Assert ($remoteLock.nonce -eq $lockA.nonce) 'acquire-lock nonce verified'
Assert (Test-Path (Join-Path $remoteRoot 'worlds\main\lock.json')) 'lock lives under worlds/main'

# T3: re-acquire our own (fresh) lock is allowed ------------------------------
$lockB = Acquire-Lock
Assert ($lockB.nonce -ne $lockA.nonce) 're-acquiring own lock issues new nonce'

# T4: fresh foreign lock is refused -------------------------------------------
$bob = [pscustomobject]@{
    holder = 'bob'; machine = 'BOBPC'; nonce = [guid]::NewGuid().ToString()
    startedUtc = (Now-Iso); heartbeatUtc = (Now-Iso); hostIp = ''; serverPort = 8211; toolVersion = '0.2.0'
}
Put-RemoteJson (Get-WorldPath 'lock.json') $bob
Assert (-not (Test-LockStale (Get-RemoteLock))) 'fresh foreign lock is not stale'
Assert-Throws { Acquire-Lock } 'acquire refuses fresh foreign lock'

# T5: stale foreign lock ------------------------------------------------------
$bob.heartbeatUtc = [DateTime]::UtcNow.AddMinutes(-60).ToString('o')
Put-RemoteJson (Get-WorldPath 'lock.json') $bob
Assert (Test-LockStale (Get-RemoteLock)) 'old heartbeat marks lock stale'
Assert-Throws { Acquire-Lock } 'stale takeover still needs explicit confirmation'
$lockC = Acquire-Lock -AllowStaleTakeover
Assert ((Get-RemoteLock).holder -eq 'tester') 'stale lock takeover succeeds when confirmed'

# T6: release ----------------------------------------------------------------
Release-Lock $lockC
Assert ($null -eq (Get-RemoteLock)) 'release-lock removes the lock'

# T7: first seed via Cmd-Upload ----------------------------------------------
$code = Cmd-Upload
$latest = Get-RemoteJson (Get-WorldPath 'latest.json')
Assert ($code -eq 0) 'seed upload returns 0'
Assert ($null -ne $latest -and [int]$latest.version -eq 1) 'seed upload creates latest v1'
Assert ($latest.worldGuid -eq $guid) 'latest records world guid'
$zips = ConvertFrom-JsonArray (Invoke-RcloneText @('lsjson', (Get-WorldPath 'saves')))
Assert ($zips.Count -eq 1) 'one zip in saves after seed'
Assert ([int](Read-WorldState).lastDownloadedVersion -eq 1) 'state tracks uploaded version'

# T8: sync-down onto a second machine ----------------------------------------
$Script:Config.serverDir = $serverDir2
Write-WorldState ([pscustomobject]@{ phase = 'idle'; lastDownloadedVersion = 0; hostingStartedUtc = '' })
$latest = Get-RemoteJson (Get-WorldPath 'latest.json')
Sync-Down $latest
$srcLevel = Get-Content -Raw (Join-Path $saveRoot1 "$guid\Level.sav")
$dstLevel = Get-Content -Raw (Join-Path $saveRoot2 "$guid\Level.sav")
Assert ($srcLevel -eq $dstLevel) 'sync-down restores identical Level.sav'
Assert (Test-Path (Join-Path $saveRoot2 "$guid\Players\p1.sav")) 'sync-down restores player files'
Assert (-not (Test-Path (Join-Path $saveRoot2 "$guid\backup"))) 'server backup folder excluded from zips'
Assert ([int](Read-WorldState).lastDownloadedVersion -eq 1) 'sync-down updates state version'

# T9: versioning + pruning (keepVersions = 3) --------------------------------
for ($i = 2; $i -le 5; $i++) {
    Set-Content -Path (Join-Path $saveRoot2 "$guid\Level.sav") -Value ('dummy-level-data-v' + $i)
    $code = Cmd-Upload
    if ($code -ne 0) { Assert $false ('upload v' + $i + ' returns 0') }
}
$latest = Get-RemoteJson (Get-WorldPath 'latest.json')
Assert ([int]$latest.version -eq 5) 'latest advances to v5'
$zips = ConvertFrom-JsonArray (Invoke-RcloneText @('lsjson', (Get-WorldPath 'saves')))
Assert ($zips.Count -eq 3) 'prune keeps only 3 zips'
$names = @($zips | ForEach-Object { $_.Name })
Assert (($names -match '^world-v0005-').Count -eq 1) 'newest zip retained'
Assert (($names -match '^world-v0002-').Count -eq 0) 'oldest zip pruned'

# T10: multiple worlds --------------------------------------------------------
$Script:WorldName = 'second'
$Script:Config.serverDir = $serverDir1
Write-WorldState ([pscustomobject]@{ phase = 'idle'; lastDownloadedVersion = 0; hostingStartedUtc = '' })
$code = Cmd-Upload
Assert ($code -eq 0) 'second world seeds independently'
$w = Get-CloudWorlds
Assert ($w.Count -eq 2 -and ($w -contains 'main') -and ($w -contains 'second')) 'get-cloudworlds lists both worlds'
Assert ($null -eq (Get-RemoteLock)) 'second world has its own (absent) lock'
$mainState = $null
$Script:WorldName = 'main'
$mainState = Read-WorldState
Assert ([int]$mainState.lastDownloadedVersion -eq 5) 'main world state untouched by second world'
Assert ((Read-StateFile).lastWorld -eq 'second') 'lastWorld tracks most recent activity'

# T11: world name resolution --------------------------------------------------
Assert ((Resolve-WorldName 'explicit') -eq 'explicit') 'explicit world name wins'
Assert ((Resolve-WorldName '') -eq 'second') 'omitted world falls back to lastWorld'
Assert-Throws { Resolve-WorldName 'bad/name' } 'invalid world name rejected'

# T12: co-op world import ----------------------------------------------------
$coopRoot = Join-Path $work 'CoopSaves'
$coopGuid = '11112222333344445555666677778888'
$coopWorld = Join-Path $coopRoot "7656000011112222\$coopGuid"
New-Item -ItemType Directory -Path (Join-Path $coopWorld 'Players') -Force | Out-Null
Set-Content -Path (Join-Path $coopWorld 'Level.sav') -Value 'coop-level-data'
Set-Content -Path (Join-Path $coopWorld 'LevelMeta.sav') -Value 'coop-meta'
Set-Content -Path (Join-Path $coopWorld 'WorldOption.sav') -Value 'coop-options'
Set-Content -Path (Join-Path $coopWorld 'Players\00000000000000000000000000000001.sav') -Value 'host-char'
Set-Content -Path (Join-Path $coopWorld 'Players\AAAA0000000000000000000000000000.sav') -Value 'guest-char'
$Script:CoopSaveRoot = $coopRoot
$Script:Config.serverDir = $serverDir1
$found = Find-CoopWorlds
Assert ($found.Count -eq 1 -and $found[0].Guid -eq $coopGuid) 'find-coopworlds discovers the world'
Import-CoopWorld -SourceDir $found[0].Path -TargetWorld 'imported'
$importedLocal = Join-Path $saveRoot1 $coopGuid
Assert (Test-Path (Join-Path $importedLocal 'Level.sav')) 'import copies world into server'
Assert (-not (Test-Path (Join-Path $importedLocal 'WorldOption.sav'))) 'import drops WorldOption.sav'
Assert (Test-Path (Join-Path $coopWorld 'WorldOption.sav')) 'original co-op save untouched'
$importedLatest = Get-RemoteJson (Get-WorldPath 'latest.json')
Assert ($null -ne $importedLatest -and [int]$importedLatest.version -eq 1) 'import seeds cloud v1'
Assert ($importedLatest.worldGuid -eq $coopGuid) 'import records source guid'
$iws = Read-WorldState
Assert (@($iws.importPlayers).Count -eq 2) 'import records pre-existing player files'
Assert-Throws { Import-CoopWorld -SourceDir $found[0].Path -TargetWorld 'imported' } 'import refuses duplicate world name'

# T13: corrupted download is rejected -----------------------------------------
$Script:WorldName = 'main'
$Script:Config.serverDir = $serverDir3
Write-WorldState ([pscustomobject]@{ phase = 'idle'; lastDownloadedVersion = 0; hostingStartedUtc = '' })
$badLatest = Get-RemoteJson (Get-WorldPath 'latest.json')
$badLatest.sha256 = 'DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF'
Assert-Throws { Sync-Down $badLatest } 'hash mismatch aborts sync-down'
Assert (-not (Test-Path (Join-Path $serverDir3 "Pal\Saved\SaveGames\0\$guid"))) 'corrupt download leaves no partial save'

# --- summary -----------------------------------------------------------------
Write-Host ''
Write-Host ('Results: {0} passed, {1} failed' -f $script:PassCount, $script:FailCount)
$env:PALRELAY_TEST = ''
Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
exit $script:FailCount
