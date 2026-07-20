# PalRelay 安裝精靈 - 給朋友的一鍵設定
# 這個檔案必須以 UTF-8 with BOM 儲存(PS 5.1 才能正確讀中文)。

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Say([string]$m)  { Write-Host $m -ForegroundColor Cyan }
function Good([string]$m) { Write-Host ('  [OK] ' + $m) -ForegroundColor Green }
function Fail([string]$m) { Write-Host ('  [X] ' + $m) -ForegroundColor Red }

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $Exe @Arguments 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Code = $code; Text = (($out | ForEach-Object { $_.ToString() }) -join "`n") }
}

function Find-Rclone {
    try { return (Get-Command rclone -ErrorAction Stop).Source } catch {}
    $wg = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path $wg) {
        $hit = Get-ChildItem $wg -Filter 'rclone.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Find-PalServer {
    $steam = $null
    try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch { return $null }
    if (-not $steam) { return $null }
    $candidates = @()
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        $m = Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' -AllMatches
        foreach ($mm in $m.Matches) { $candidates += ($mm.Groups[1].Value -replace '\\\\', '\') }
    }
    $candidates += $steam
    foreach ($c in $candidates) {
        $ps = Join-Path $c 'steamapps\common\PalServer'
        if (Test-Path (Join-Path $ps 'PalServer.exe')) { return $ps }
    }
    return $null
}

Write-Host ''
Say '=============================================='
Say '  PalRelay 安裝精靈'
Say '  帕魯輪流開服工具 - 大約需要 3 分鐘'
Say '=============================================='
Write-Host ''

# 已有設定就不重跑
$configPath = Join-Path $toolDir 'config.json'
if (Test-Path $configPath) {
    $ans = Read-Host '偵測到已設定過。要重新設定嗎?(y = 重來 / 直接 Enter = 離開)'
    if ($ans -notmatch '^[Yy]') { Say '沒有變更,再見!'; exit 0 }
}

# --- 步驟 1/5:rclone(雲端同步工具) ---------------------------------------
Say '[步驟 1/5] 檢查雲端同步工具 rclone...'
$rclone = Find-Rclone
if ($rclone) {
    Good ('已安裝:' + $rclone)
} else {
    Say '  尚未安裝,現在自動安裝(來源為 rclone 官方,約 20MB)...'
    $r = Invoke-Native 'winget' @('install', 'Rclone.Rclone', '--silent', '--accept-source-agreements', '--accept-package-agreements')
    $rclone = Find-Rclone
    if (-not $rclone) {
        Fail '自動安裝失敗。請手動到 https://rclone.org/downloads/ 下載後重新執行本精靈。'
        exit 1
    }
    Good ('安裝完成:' + $rclone)
}

# --- 步驟 2/5:群組的雲端資料夾 ----------------------------------------------
Write-Host ''
Say '[步驟 2/5] 群組的 Google Drive 雲端資料夾'
$rcloneConf = Join-Path $toolDir 'rclone.conf'
$mode = ''
while ($mode -ne '1' -and $mode -ne '2') {
    $mode = (Read-Host '  你要 (1) 加入朋友的群組 還是 (2) 建立全新群組?輸入 1 或 2').Trim()
}
$isFounder = ($mode -eq '2')
$shareUrl = ''
if ($isFounder) {
    Say '  接下來瀏覽器會開啟 Google 登入頁:用你的 Google 帳號登入並按「允許」。'
    Read-Host '  準備好後按 Enter 繼續'
    $r = Invoke-Native $rclone @('config', 'create', 'gdrive', 'drive', 'scope=drive', '--config', $rcloneConf)
    if ($r.Code -ne 0) { Fail ('Google 授權失敗:' + $r.Text); exit 1 }
    Say '  正在你的雲端硬碟建立「PalRelay」資料夾...'
    $r = Invoke-Native $rclone @('--config', $rcloneConf, 'mkdir', 'gdrive:PalRelay')
    if ($r.Code -ne 0) { Fail ('建立資料夾失敗:' + $r.Text); exit 1 }
    $r = Invoke-Native $rclone @('--config', $rcloneConf, 'lsjson', '--dirs-only', 'gdrive:')
    $folderId = $null
    if ($r.Code -eq 0 -and $r.Text.Trim()) {
        $dirs = ConvertFrom-Json -InputObject $r.Text
        foreach ($d in @($dirs)) {
            if ($d.Name -eq 'PalRelay' -and -not $folderId) { $folderId = [string]$d.ID }
        }
    }
    if (-not $folderId) { Fail '找不到剛建立的資料夾 ID,請重跑一次精靈。'; exit 1 }
    $r = Invoke-Native $rclone @('config', 'update', 'gdrive', ('root_folder_id=' + $folderId), '--config', $rcloneConf)
    if ($r.Code -ne 0) { Fail ('鎖定資料夾失敗:' + $r.Text); exit 1 }
    $shareUrl = 'https://drive.google.com/drive/folders/' + $folderId
    [IO.File]::WriteAllText((Join-Path $toolDir 'share-link.txt'), $shareUrl, (New-Object System.Text.UTF8Encoding($false)))
    Good '資料夾已建立!'
    Say '  瀏覽器即將開啟這個資料夾。請按右上角「共用」,把每位朋友的'
    Say '  Google 帳號加為「編輯者」,然後把這條連結傳到群組(朋友 setup 時要貼):'
    Say ('    ' + $shareUrl)
    Say '  (連結也已存到 share-link.txt,隨時找得到)'
    Start-Process $shareUrl
    Read-Host '  完成共用(或想稍後再共用)後按 Enter 繼續'
} else {
    Say '  (請群主把共用資料夾的連結傳給你;群主的連結在他的 share-link.txt)'
    $folderId = $null
    while (-not $folderId) {
        $link = Read-Host '  貼上共用資料夾的連結'
        if ($link -match '/folders/([A-Za-z0-9_-]{10,})') { $folderId = $Matches[1] }
        elseif ($link.Trim() -match '^[A-Za-z0-9_-]{10,}$') { $folderId = $link.Trim() }
        else { Fail '  看不懂這個連結,請直接複製瀏覽器網址列的完整連結再試一次。' }
    }
    Good ('資料夾 ID:' + $folderId)
    Say '  接下來瀏覽器會開啟 Google 登入頁:請用你自己的 Google 帳號登入並按「允許」。'
    Read-Host '  準備好後按 Enter 繼續'
    $r = Invoke-Native $rclone @('config', 'create', 'gdrive', 'drive', 'scope=drive', ('root_folder_id=' + $folderId), '--config', $rcloneConf)
    if ($r.Code -ne 0) {
        Fail ('Google 授權失敗:' + $r.Text)
        exit 1
    }
}
$r = Invoke-Native $rclone @('--config', $rcloneConf, 'lsjson', 'gdrive:')
if ($r.Code -ne 0) {
    Fail '連不上資料夾。請確認群主有把資料夾分享給你(編輯者權限)。'
    exit 1
}
Good '雲端資料夾連線成功!'

# --- 步驟 3/5:Palworld 伺服器 ------------------------------------------------
Write-Host ''
Say '[步驟 3/5] 檢查 Palworld 專用伺服器...'
$serverDir = Find-PalServer
if ($serverDir) {
    Good ('已安裝:' + $serverDir)
} else {
    Say '  尚未安裝。即將開啟 Steam 安裝視窗(免費,約 5GB),請按「安裝」。'
    Start-Process 'steam://install/2394010'
    Say '  等待安裝完成中...(裝好會自動繼續,想中斷按 Ctrl+C)'
    $waited = 0
    while (-not $serverDir) {
        Start-Sleep -Seconds 10
        $waited += 10
        if ($waited % 60 -eq 0) { Say ('  仍在等待 Steam 下載...(已等 ' + ($waited / 60) + ' 分鐘)') }
        $serverDir = Find-PalServer
    }
    Good ('安裝完成:' + $serverDir)
}

# --- 步驟 4/5:你的暱稱 -------------------------------------------------------
Write-Host ''
Say '[步驟 4/5] 基本資料'
$name = ''
while (-not $name) {
    $name = (Read-Host '  你的暱稱(建議英文/數字,會顯示給朋友看)').Trim()
}

# 群組密碼:已有 group.json 就自動沿用,否則你是群主、幫群組生一組
$adminPw = ''
$r = Invoke-Native $rclone @('--config', $rcloneConf, 'cat', 'gdrive:/group.json')
if ($r.Code -eq 0 -and $r.Text.Trim()) {
    Good '已讀取群組設定(管理密碼自動套用,不用輸入)'
} else {
    Say '  這個資料夾還沒有群組設定,看來你是群主!'
    $adminPw = (Read-Host '  幫群組設一組伺服器管理密碼(直接 Enter = 自動產生)').Trim()
    if (-not $adminPw) {
        $adminPw = 'pal-' + [guid]::NewGuid().ToString('n').Substring(0, 10)
        Good ('已自動產生管理密碼:' + $adminPw)
    }
}

# --- 步驟 5/5:寫入設定 -------------------------------------------------------
Write-Host ''
Say '[步驟 5/5] 寫入設定...'
$cfg = [ordered]@{
    playerName        = $name
    remote            = 'gdrive:'
    serverDir         = $serverDir
    rclonePath        = $rclone
    rcloneConfig      = 'rclone.conf'
    serverExe         = 'PalServer.exe'
    serverArgs        = @()
    adminPassword     = $adminPw
    serverPort        = 8211
    restPort          = 8212
    heartbeatMinutes  = 5
    staleMinutes      = 20
    checkpointMinutes = 0
    keepVersions      = 10
    worldGuid         = ''
}
[IO.File]::WriteAllText($configPath, ($cfg | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
Good 'config.json 已建立'

# 煙霧測試:列出世界(順便觸發 group.json 建立 / 雲端遷移)
Write-Host ''
Say '最後檢查:連線測試...'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $toolDir 'palrelay.ps1') worlds
if ($LASTEXITCODE -ne 0) {
    Fail '連線測試失敗,請把上面的錯誤訊息傳給群主。'
    exit 1
}

Write-Host ''
Say '=============================================='
Say '  設定完成!'
Say '  之後想玩:雙擊 palrelay-gui.cmd'
if ($shareUrl) {
    Say ''
    Say '  別忘了把資料夾連結傳給朋友(也存在 share-link.txt):'
    Say ('  ' + $shareUrl)
}
Say ''
Say '  (建議也安裝 Tailscale 讓朋友連線更簡單:'
Say '   https://tailscale.com/download 全員安裝後互加好友)'
Say '=============================================='
