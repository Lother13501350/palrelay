# PalRelay GUI - 圖形介面(WPF,Windows 內建,不需安裝任何東西)
# 這個檔案必須以 UTF-8 with BOM 儲存(PS 5.1 才能正確讀中文)。
# 底層邏輯完全重用 palrelay.ps1;GUI 只負責按鈕與狀態顯示。

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName Microsoft.VisualBasic

$guiDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:PALRELAY_TEST = '1'
. (Join-Path $guiDir 'palrelay.ps1')
$env:PALRELAY_TEST = ''

# ---------- GUI 狀態 ----------
$Script:GuiHosting = $false
$Script:GuiProc = $null
$Script:GuiLock = $null
$Script:GuiGuid = $null
$Script:GuiLastHb = [DateTime]::UtcNow
$Script:GuiTicks = 0

# ---------- 視窗 ----------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PalRelay - 帕魯輪流開服" Height="540" Width="560"
        WindowStartupLocation="CenterScreen" Background="#1e2430">
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <DockPanel Grid.Row="0" Margin="0,0,0,10">
      <TextBlock Text="世界:" Foreground="#cfd8e3" VerticalAlignment="Center" FontSize="14" Margin="0,0,8,0"/>
      <Button x:Name="NewWorldBtn" DockPanel.Dock="Right" Content="+ 新世界" Width="80" Margin="8,0,0,0"/>
      <Button x:Name="RefreshBtn" DockPanel.Dock="Right" Content="重新整理" Width="80" Margin="8,0,0,0"/>
      <ComboBox x:Name="WorldCombo" FontSize="14"/>
    </DockPanel>

    <Border Grid.Row="1" Background="#2a3242" CornerRadius="8" Padding="12" Margin="0,0,0,10">
      <StackPanel>
        <TextBlock x:Name="StatusText" Text="載入中..." Foreground="#e8eef7" FontSize="14" TextWrapping="Wrap"/>
        <TextBlock x:Name="VersionText" Text="" Foreground="#9fb0c3" FontSize="12" Margin="0,6,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>

    <DockPanel Grid.Row="2" Margin="0,0,0,10">
      <Button x:Name="CopyBtn" DockPanel.Dock="Right" Content="複製" Width="60" Margin="8,0,0,0" IsEnabled="False"/>
      <TextBox x:Name="ConnectBox" IsReadOnly="True" FontSize="13" Text="(開服後這裡會顯示朋友要輸入的連線位址)"
               Background="#2a3242" Foreground="#9fb0c3" BorderThickness="0" Padding="8"/>
    </DockPanel>

    <Button x:Name="ActionBtn" Grid.Row="3" Content="開始當主機" Height="58" FontSize="20" FontWeight="Bold"
            Background="#3fa860" Foreground="White" BorderThickness="0" Margin="0,0,0,10"/>

    <TextBox x:Name="LogBox" Grid.Row="4" IsReadOnly="True" VerticalScrollBarVisibility="Auto"
             Background="#161b24" Foreground="#9fb0c3" BorderThickness="0" Padding="8"
             FontFamily="Consolas" FontSize="12" TextWrapping="Wrap"/>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$WorldCombo = $window.FindName('WorldCombo')
$RefreshBtn = $window.FindName('RefreshBtn')
$NewWorldBtn = $window.FindName('NewWorldBtn')
$StatusText = $window.FindName('StatusText')
$VersionText = $window.FindName('VersionText')
$ConnectBox = $window.FindName('ConnectBox')
$CopyBtn = $window.FindName('CopyBtn')
$ActionBtn = $window.FindName('ActionBtn')
$LogBox = $window.FindName('LogBox')

function Update-Ui {
    $window.Dispatcher.Invoke([Windows.Threading.DispatcherPriority]::Render, [action]{})
}

function Gui-Log([string]$m) {
    $LogBox.AppendText(('[' + [DateTime]::Now.ToString('HH:mm:ss') + '] ' + $m + "`r`n"))
    $LogBox.ScrollToEnd()
    Update-Ui
}

# 覆寫 palrelay.ps1 的輸出與詢問:訊息進 log、詢問改彈窗
function Write-Info([string]$m) { Gui-Log $m }
function Write-Warn([string]$m) { Gui-Log ('警告: ' + $m) }
function Write-Err([string]$m)  { Gui-Log ('錯誤: ' + $m) }
function Confirm-Prompt {
    param([string]$Message, [bool]$DefaultYes)
    $r = [Windows.MessageBox]::Show($Message, 'PalRelay', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
    return ($r -eq [Windows.MessageBoxResult]::Yes)
}

function Show-Error([string]$Message) {
    Gui-Log ('錯誤: ' + $Message)
    [void][Windows.MessageBox]::Show($Message, 'PalRelay 發生問題', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error)
}

function Refresh-Worlds {
    $current = [string]$WorldCombo.SelectedItem
    $WorldCombo.Items.Clear()
    $worlds = @()
    try { $worlds = Get-CloudWorlds } catch { Gui-Log ('讀取世界清單失敗: ' + $_.Exception.Message) }
    if ($worlds.Count -eq 0) { $worlds = @('main') }
    foreach ($w in $worlds) { [void]$WorldCombo.Items.Add($w) }
    $pick = $current
    if (-not $pick) { $pick = (Read-StateFile).lastWorld }
    if (-not $pick -or -not $WorldCombo.Items.Contains($pick)) { $pick = $WorldCombo.Items[0] }
    $WorldCombo.SelectedItem = $pick
}

function Refresh-Status {
    if ($null -eq $WorldCombo.SelectedItem) { return }
    $Script:WorldName = [string]$WorldCombo.SelectedItem
    if ($Script:GuiHosting) { return }
    try {
        $lock = Get-RemoteLock
        $latest = Get-RemoteJson (Get-WorldPath 'latest.json')
        if ($lock) {
            if (Test-LockStale $lock) {
                $StatusText.Text = ('狀態:' + $lock.holder + ' 的鎖已過期(可能當機了),可接管')
                $StatusText.Foreground = 'Orange'
            } else {
                $StatusText.Text = ('狀態:' + $lock.holder + ' 正在開服中')
                $StatusText.Foreground = '#e07a5f'
                if ($lock.PSObject.Properties['hostIp'] -and $lock.hostIp) {
                    $ConnectBox.Text = ($lock.hostIp + ':' + $lock.serverPort)
                    $CopyBtn.IsEnabled = $true
                }
            }
        } else {
            $StatusText.Text = '狀態:世界空閒,可以開服!'
            $StatusText.Foreground = '#7ec97f'
            $ConnectBox.Text = '(開服後這裡會顯示朋友要輸入的連線位址)'
            $CopyBtn.IsEnabled = $false
        }
        if ($latest) {
            $VersionText.Text = ('最新存檔:v' + $latest.version + ' / ' + $latest.uploadedBy + ' 上傳 / ' + $latest.uploadedUtc)
        } else {
            $VersionText.Text = '最新存檔:還沒有(第一次開服會自動建立新世界)'
        }
    } catch {
        $StatusText.Text = ('狀態讀取失敗:' + $_.Exception.Message)
        $StatusText.Foreground = 'Orange'
    }
}

function Set-HostingUi([bool]$On) {
    $Script:GuiHosting = $On
    if ($On) {
        $ActionBtn.Content = '收工上傳'
        $ActionBtn.Background = '#e07a5f'
        $StatusText.Text = ('狀態:你正在開服(世界:' + $Script:WorldName + ')')
        $StatusText.Foreground = '#e07a5f'
        if ($Script:GuiLock -and $Script:GuiLock.hostIp) {
            $ConnectBox.Text = ($Script:GuiLock.hostIp + ':' + $Script:GuiLock.serverPort)
            $CopyBtn.IsEnabled = $true
        } else {
            $ConnectBox.Text = '(沒偵測到 Tailscale,朋友需用你的對外 IP 連線)'
        }
        $WorldCombo.IsEnabled = $false
        $NewWorldBtn.IsEnabled = $false
    } else {
        $ActionBtn.Content = '開始當主機'
        $ActionBtn.Background = '#3fa860'
        $WorldCombo.IsEnabled = $true
        $NewWorldBtn.IsEnabled = $true
        Refresh-Status
    }
    Update-Ui
}

function Gui-Start {
    $Script:WorldName = [string]$WorldCombo.SelectedItem
    $ActionBtn.IsEnabled = $false
    try {
        Test-Prereqs
        $ws = Read-WorldState
        if ($ws.phase -eq 'hosting') {
            if (Confirm-Prompt '上次開服沒有正常上傳(當機?)。要先把本機存檔補上傳嗎?' $true) {
                if ((Cmd-Upload) -ne 0) { throw '補上傳失敗,請看紀錄。' }
            } else {
                $ws.phase = 'idle'; Write-WorldState $ws
            }
        }
        $lock = Get-RemoteLock
        $stale = $false
        if ($lock -and -not (Test-LockOurs $lock)) {
            if (-not (Test-LockStale $lock)) {
                Show-Error ($lock.holder + ' 正在開這個世界,同時只能有一個人開服。')
                return
            }
            if (-not (Confirm-Prompt ($lock.holder + ' 的鎖已過期(可能當機)。接管會失去他沒上傳的進度,確定接管?') $false)) { return }
            $stale = $true
        }
        Gui-Log ('取得世界「' + $Script:WorldName + '」的鎖...')
        if ($stale) { $Script:GuiLock = Acquire-Lock -AllowStaleTakeover } else { $Script:GuiLock = Acquire-Lock }
        Update-Ui
        $latest = Get-RemoteJson (Get-WorldPath 'latest.json')
        Sync-Down $latest
        $Script:GuiGuid = Resolve-WorldGuid $latest
        if ($Script:GuiGuid) { Ensure-DedicatedServerName $Script:GuiGuid }
        $base = 0
        if ($latest) { $base = [int]$latest.version }
        $Script:SessionVersion = $base
        $ws = Read-WorldState
        $ws.phase = 'hosting'; $ws.hostingStartedUtc = (Now-Iso)
        Write-WorldState $ws
        Gui-Log '啟動伺服器...'
        $Script:GuiProc = Start-Server
        $Script:GuiLastHb = [DateTime]::UtcNow
        Set-HostingUi $true
        Gui-Log '伺服器啟動中,朋友稍等一下就能連線。收工時按「收工上傳」。'
    } catch {
        Show-Error $_.Exception.Message
        if ($Script:GuiLock -and -not $Script:GuiProc) {
            try { Release-Lock $Script:GuiLock } catch {}
            $Script:GuiLock = $null
        }
    } finally {
        $ActionBtn.IsEnabled = $true
        Update-Ui
    }
}

function Gui-Stop([bool]$ServerAlreadyDead) {
    $ActionBtn.IsEnabled = $false
    try {
        if (-not $ServerAlreadyDead) {
            Gui-Log '通知伺服器存檔並關機...'
            Stop-ServerGraceful $Script:GuiProc | Out-Null
        }
        if (-not $Script:GuiGuid) { $Script:GuiGuid = Resolve-WorldGuid $null }
        if (-not $Script:GuiGuid) { throw '找不到世界存檔資料夾,無法上傳。' }
        $newVersion = $Script:SessionVersion + 1
        Publish-Save -SourceDir (Join-Path (Get-SaveRoot) $Script:GuiGuid) -WorldGuid $Script:GuiGuid -NewVersion $newVersion | Out-Null
        $ws = Read-WorldState
        $ws.phase = 'idle'; $ws.lastDownloadedVersion = $newVersion; $ws.hostingStartedUtc = ''
        Write-WorldState $ws
        Release-Lock $Script:GuiLock
        $Script:GuiLock = $null
        $Script:GuiProc = $null
        Set-HostingUi $false
        Gui-Log ('完成!存檔 v' + $newVersion + ' 已上傳,世界已釋放給下一位。')
    } catch {
        Show-Error ($_.Exception.Message + [Environment]::NewLine + '存檔尚未上傳,鎖已保留。修好問題後再按一次「收工上傳」。')
    } finally {
        $ActionBtn.IsEnabled = $true
        Update-Ui
    }
}

# ---------- 事件 ----------
$ActionBtn.Add_Click({
    if ($Script:GuiHosting) { Gui-Stop $false } else { Gui-Start }
})

$RefreshBtn.Add_Click({ Refresh-Worlds; Refresh-Status })

$NewWorldBtn.Add_Click({
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('新世界的名字(例如:建築世界):', 'PalRelay - 新世界', '')
    if (-not $name) { return }
    if ($name -match '[\\/:*?"<>|]') { Show-Error '名字不能包含 \ / : * ? " < > |'; return }
    if (-not $WorldCombo.Items.Contains($name)) { [void]$WorldCombo.Items.Add($name) }
    $WorldCombo.SelectedItem = $name
    Gui-Log ('已選擇新世界「' + $name + '」,按「開始當主機」即建立。')
})

$WorldCombo.Add_SelectionChanged({ Refresh-Status })

$CopyBtn.Add_Click({
    try { Set-Clipboard -Value $ConnectBox.Text; Gui-Log ('已複製連線位址:' + $ConnectBox.Text) } catch {}
})

$window.Add_Closing({
    param($s, $e)
    if ($Script:GuiHosting) {
        if (-not (Confirm-Prompt '伺服器還在運作,直接關閉將不會上傳進度(之後要用補上傳復原)。確定要關閉?' $false)) {
            $e.Cancel = $true
        }
    }
})

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(10)
$timer.Add_Tick({
    $Script:GuiTicks++
    if ($Script:GuiHosting) {
        if (-not (Test-ServerAlive $Script:GuiProc)) {
            Gui-Log '伺服器自己結束了。'
            if (Confirm-Prompt '伺服器已停止。要把目前的本機存檔上傳嗎?(建議:是)' $true) {
                Gui-Stop $true
            } else {
                Set-HostingUi $false
            }
            return
        }
        if (([DateTime]::UtcNow - $Script:GuiLastHb).TotalMinutes -ge [double]$Script:Config.heartbeatMinutes) {
            try { Update-LockHeartbeat } catch { Gui-Log ('心跳失敗: ' + $_.Exception.Message) }
            $Script:GuiLastHb = [DateTime]::UtcNow
        }
    } elseif (($Script:GuiTicks % 3) -eq 0) {
        Refresh-Status
    }
})

# ---------- 啟動 ----------
try {
    $Script:Config = Read-Config
} catch {
    [void][Windows.MessageBox]::Show('還沒完成設定:請先雙擊 setup.cmd 跑一次安裝精靈。' + [Environment]::NewLine + $_.Exception.Message, 'PalRelay', 'OK', 'Warning')
    exit 1
}
try { Ensure-CloudLayout } catch { Gui-Log ('雲端檢查失敗: ' + $_.Exception.Message) }
Refresh-Worlds
Refresh-Status
Gui-Log ('PalRelay v' + $Script:ToolVersion + ' 已就緒。')
$timer.Start()

if ($env:PALRELAY_GUI_TEST -eq '1') {
    Write-Host 'GUI OK (test mode, window not shown)'
    exit 0
}
[void]$window.ShowDialog()
