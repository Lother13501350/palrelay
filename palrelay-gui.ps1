# PalRelay GUI v2 - 圖形介面(WPF,Windows 內建,不需安裝任何東西)
# 這個檔案必須以 UTF-8 with BOM 儲存(PS 5.1 才能正確讀中文)。
# 底層邏輯完全重用 palrelay.ps1;GUI 只負責介面與流程引導。

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
$Script:GuiOptCache = @{}

$Script:SettingLabels = [ordered]@{
    'Difficulty'                = '難度'
    'ExpRate'                   = '經驗值倍率'
    'WorkSpeedRate'             = '工作速度倍率'
    'PalCaptureRate'            = '捕捉倍率'
    'PalEggDefaultHatchingTime' = '孵蛋時間(小時)'
    'CollectionDropRate'        = '採集掉落倍率'
    'EnemyDropItemRate'         = '擊殺掉落倍率'
    'PlayerDamageRateDefense'   = '玩家受傷倍率'
    'PlayerStomachDecreaceRate' = '飽食消耗倍率'
    'PlayerStaminaDecreaceRate' = '耐力消耗倍率'
    'DayTimeSpeedRate'          = '白天流速'
    'NightTimeSpeedRate'        = '夜晚流速'
    'DeathPenalty'              = '死亡懲罰'
    'BaseCampWorkerMaxNum'      = '基地帕魯上限'
}
$Script:DeathPenaltyNames = @{
    'None' = '無'; 'Item' = '掉道具'; 'ItemAndEquipment' = '掉道具與裝備'; 'All' = '全部掉落'
}

# ---------- 視窗 ----------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PalRelay - 帕魯輪流開服" Height="660" Width="900"
        WindowStartupLocation="CenterScreen" Background="#1e2430">
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="170"/>
    </Grid.RowDefinitions>

    <DockPanel Grid.Row="0" Margin="0,0,0,10">
      <TextBlock Text="世界:" Foreground="#cfd8e3" VerticalAlignment="Center" FontSize="14" Margin="0,0,8,0"/>
      <Button x:Name="ImportBtn" DockPanel.Dock="Right" Content="匯入既有世界" Width="100" Margin="8,0,0,0"/>
      <Button x:Name="NewWorldBtn" DockPanel.Dock="Right" Content="+ 新世界" Width="76" Margin="8,0,0,0"/>
      <Button x:Name="RefreshBtn" DockPanel.Dock="Right" Content="重新整理" Width="76" Margin="8,0,0,0"/>
      <ComboBox x:Name="WorldCombo" FontSize="14"/>
    </DockPanel>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="2*"/>
        <ColumnDefinition Width="1*"/>
      </Grid.ColumnDefinitions>

      <StackPanel Grid.Column="0" Margin="0,0,10,0">
        <Border Background="#2a3242" CornerRadius="8" Padding="12" Margin="0,0,0,10">
          <StackPanel>
            <TextBlock x:Name="StatusText" Text="載入中..." Foreground="#e8eef7" FontSize="15" FontWeight="Bold" TextWrapping="Wrap"/>
            <TextBlock x:Name="VersionText" Text="" Foreground="#9fb0c3" FontSize="12" Margin="0,6,0,0" TextWrapping="Wrap"/>
            <TextBlock x:Name="DetailText" Text="" Foreground="#7a8aa0" FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>

        <Border Background="#2a3242" CornerRadius="8" Padding="12" Margin="0,0,0,10">
          <StackPanel>
            <TextBlock Text="世界設定" Foreground="#cfd8e3" FontSize="13" FontWeight="Bold" Margin="0,0,0,6"/>
            <TextBlock x:Name="SettingsText" Text="(讀取中...)" Foreground="#9fb0c3" FontSize="12" TextWrapping="Wrap" LineHeight="20"/>
          </StackPanel>
        </Border>

        <DockPanel>
          <Button x:Name="CopyBtn" DockPanel.Dock="Right" Content="複製" Width="60" Margin="8,0,0,0" IsEnabled="False"/>
          <TextBox x:Name="ConnectBox" IsReadOnly="True" FontSize="13" Text="(開服後這裡會顯示朋友要輸入的連線位址)"
                   Background="#2a3242" Foreground="#9fb0c3" BorderThickness="0" Padding="8"/>
        </DockPanel>
      </StackPanel>

      <StackPanel Grid.Column="1">
        <Button x:Name="ActionBtn" Content="開始當主機" Height="64" FontSize="20" FontWeight="Bold"
                Background="#3fa860" Foreground="White" BorderThickness="0" Margin="0,0,0,12"/>
        <Button x:Name="FixhostBtn" Content="完成角色搬遷(匯入後)" Height="34" Margin="0,0,0,8"/>
        <Button x:Name="FixmapBtn" Content="修復地圖探索" Height="34" Margin="0,0,0,8"/>
        <Button x:Name="OpenFolderBtn" Content="開啟伺服器存檔資料夾" Height="34" Margin="0,0,0,8"/>
        <Button x:Name="HelpBtn" Content="使用說明(GitHub)" Height="34" Margin="0,0,0,8"/>
        <TextBlock x:Name="ToolVerText" Text="" Foreground="#55647a" FontSize="11" Margin="0,8,0,0" HorizontalAlignment="Center"/>
      </StackPanel>
    </Grid>

    <TextBox x:Name="LogBox" Grid.Row="2" IsReadOnly="True" VerticalScrollBarVisibility="Auto"
             Background="#161b24" Foreground="#9fb0c3" BorderThickness="0" Padding="8" Margin="0,10,0,0"
             FontFamily="Consolas" FontSize="12" TextWrapping="Wrap"/>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
foreach ($name in @('WorldCombo','RefreshBtn','NewWorldBtn','ImportBtn','StatusText','VersionText','DetailText',
                    'SettingsText','ConnectBox','CopyBtn','ActionBtn','FixhostBtn','FixmapBtn','OpenFolderBtn',
                    'HelpBtn','ToolVerText','LogBox')) {
    Set-Variable -Name $name -Value $window.FindName($name)
}

function Update-Ui {
    $window.Dispatcher.Invoke([Windows.Threading.DispatcherPriority]::Render, [action]{})
}

function Gui-Log([string]$m) {
    $LogBox.AppendText(('[' + [DateTime]::Now.ToString('HH:mm:ss') + '] ' + $m + "`r`n"))
    $LogBox.ScrollToEnd()
    Update-Ui
}

# 覆寫 palrelay.ps1 的 console I/O:訊息進 log、詢問改彈窗
function Write-Info([string]$m) { Gui-Log $m }
function Write-Warn([string]$m) { Gui-Log ('警告: ' + $m) }
function Write-Err([string]$m)  { Gui-Log ('錯誤: ' + $m) }
function Confirm-Prompt {
    param([string]$Message, [bool]$DefaultYes)
    $r = [Windows.MessageBox]::Show($Message, 'PalRelay', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
    return ($r -eq [Windows.MessageBoxResult]::Yes)
}
function Read-Host([string]$Prompt) {
    return [Microsoft.VisualBasic.Interaction]::InputBox($Prompt, 'PalRelay', '')
}

function Show-Error([string]$Message) {
    Gui-Log ('錯誤: ' + $Message)
    [void][Windows.MessageBox]::Show($Message, 'PalRelay 發生問題', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error)
}

function Format-WorldSettings($Opt) {
    if ($null -eq $Opt) { return '此世界沒有自訂設定(使用預設值),或尚未由 v0.5+ 匯入。' }
    $ov = $Opt.optionOverrides
    if ($null -eq $ov) { return '(無設定資料)' }
    $lines = @()
    $shown = @()
    foreach ($key in $Script:SettingLabels.Keys) {
        $p = $ov.PSObject.Properties[$key]
        if ($null -eq $p) { continue }
        $val = [string]$p.Value
        $num = 0.0
        if ([double]::TryParse($val, [ref]$num)) { $val = $num.ToString('0.##') }
        if ($key -eq 'DeathPenalty' -and $Script:DeathPenaltyNames.ContainsKey($val)) { $val = $Script:DeathPenaltyNames[$val] }
        $lines += ($Script:SettingLabels[$key] + ':' + $val)
        $shown += $key
    }
    $extra = @($ov.PSObject.Properties | Where-Object { $shown -notcontains $_.Name }).Count
    $text = ($lines -join '   ')
    if ($extra -gt 0) { $text += ('   (其他 ' + $extra + ' 項)') }
    if (-not $text) { $text = '(全部使用預設值)' }
    return $text
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
                $StatusText.Text = '狀態:' + $lock.holder + ' 的鎖已過期(可能當機),可接管'
                $StatusText.Foreground = 'Orange'
            } else {
                $StatusText.Text = '狀態:' + $lock.holder + ' 正在開服中'
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
            $mb = 0.0
            if ($latest.PSObject.Properties['sizeBytes']) { $mb = [math]::Round([double]$latest.sizeBytes / 1MB, 1) }
            $when = [string]$latest.uploadedUtc
            try { $when = (Parse-Utc $latest.uploadedUtc).ToLocalTime().ToString('MM/dd HH:mm') } catch {}
            $VersionText.Text = '最新存檔:v' + $latest.version + '(' + $mb + ' MB)由 ' + $latest.uploadedBy + ' 於 ' + $when + ' 上傳'
            $DetailText.Text = '世界 ID:' + $latest.worldGuid
        } else {
            $VersionText.Text = '最新存檔:還沒有(第一次開服會自動建立新世界)'
            $DetailText.Text = ''
        }
        # 世界設定(有快取)
        if (-not $Script:GuiOptCache.ContainsKey($Script:WorldName)) {
            $opt = $null
            try { $opt = Get-RemoteJson (Get-WorldPath 'options.json') } catch {}
            $Script:GuiOptCache[$Script:WorldName] = $opt
        }
        $SettingsText.Text = Format-WorldSettings $Script:GuiOptCache[$Script:WorldName]
    } catch {
        $StatusText.Text = '狀態讀取失敗:' + $_.Exception.Message
        $StatusText.Foreground = 'Orange'
    }
}

function Set-HostingUi([bool]$On) {
    $Script:GuiHosting = $On
    foreach ($b in @($WorldCombo, $NewWorldBtn, $ImportBtn, $FixhostBtn, $FixmapBtn, $RefreshBtn)) { $b.IsEnabled = (-not $On) }
    if ($On) {
        $ActionBtn.Content = '收工上傳'
        $ActionBtn.Background = '#e07a5f'
        $StatusText.Text = '狀態:你正在開服(世界:' + $Script:WorldName + ')'
        $StatusText.Foreground = '#e07a5f'
        if ($Script:GuiLock -and $Script:GuiLock.hostIp) {
            $ConnectBox.Text = ($Script:GuiLock.hostIp + ':' + $Script:GuiLock.serverPort)
            $CopyBtn.IsEnabled = $true
            $src = ''
            if ($Script:GuiLock.PSObject.Properties['hostIpSource']) { $src = [string]$Script:GuiLock.hostIpSource }
            if ($src -eq 'public') {
                Gui-Log '注意:這是對外 IP,你的路由器必須開 UDP 8211 轉發朋友才連得進來;全員安裝 Tailscale 可免設定。'
            }
        } else {
            $ConnectBox.Text = '(抓不到連線位址:請安裝 Tailscale 後重開)'
        }
    } else {
        $ActionBtn.Content = '開始當主機'
        $ActionBtn.Background = '#3fa860'
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
        if ($Script:GuiGuid) {
            Ensure-DedicatedServerName $Script:GuiGuid
            Protect-ClientMapData $Script:GuiGuid
        }
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

function Show-ImportDialog {
    $coop = Find-CoopWorlds
    if ($coop.Count -eq 0) {
        Show-Error '在這台電腦上找不到任何合作模式(co-op)世界。'
        return $null
    }
    [xml]$dxaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="匯入既有世界" Height="440" Width="520" WindowStartupLocation="CenterOwner" Background="#1e2430">
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="選擇要搬進雲端的世界(原存檔不會被更動):" Foreground="#cfd8e3" Margin="0,0,0,8"/>
    <ListBox x:Name="WorldsList" Grid.Row="1" Background="#2a3242" Foreground="#e8eef7" BorderThickness="0" FontSize="13"/>
    <DockPanel Grid.Row="2" Margin="0,10,0,0">
      <TextBlock Text="雲端世界名稱:" Foreground="#cfd8e3" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBox x:Name="NameBox" FontSize="13" Padding="4"/>
    </DockPanel>
    <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="OkBtn" Content="匯入" Width="90" Height="30" Margin="0,0,8,0" Background="#3fa860" Foreground="White" BorderThickness="0"/>
      <Button x:Name="CancelBtn" Content="取消" Width="90" Height="30"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $dreader = New-Object System.Xml.XmlNodeReader $dxaml
    $dlg = [Windows.Markup.XamlReader]::Load($dreader)
    $dlg.Owner = $window
    $list = $dlg.FindName('WorldsList')
    $nameBox = $dlg.FindName('NameBox')
    foreach ($w in $coop) {
        $label = Get-CoopWorldName $w.Path
        if (-not $label) { $label = '(讀不到名稱)' }
        [void]$list.Items.Add($label + '    最後遊玩 ' + $w.Modified.ToString('yyyy/MM/dd HH:mm'))
    }
    $list.SelectedIndex = 0
    $result = @{ Ok = $false }
    $dlg.FindName('OkBtn').Add_Click({
        if ($list.SelectedIndex -lt 0) { return }
        if (-not $nameBox.Text.Trim()) { [void][Windows.MessageBox]::Show('請輸入雲端世界名稱'); return }
        $result.Ok = $true
        $dlg.Close()
    })
    $dlg.FindName('CancelBtn').Add_Click({ $dlg.Close() })
    [void]$dlg.ShowDialog()
    if (-not $result.Ok) { return $null }
    return @{ Source = $coop[$list.SelectedIndex]; Name = $nameBox.Text.Trim() }
}

function Gui-Import {
    $pick = Show-ImportDialog
    if ($null -eq $pick) { return }
    if ($pick.Name -match '[\\/:*?"<>|]') { Show-Error '名稱不能包含 \ / : * ? " < > |'; return }
    try {
        Gui-Log ('匯入「' + $pick.Name + '」中,請稍候...')
        Import-CoopWorld -SourceDir $pick.Source.Path -TargetWorld $pick.Name
        Refresh-Worlds
        $WorldCombo.SelectedItem = $pick.Name
        [void][Windows.MessageBox]::Show(
            ('世界已上雲!接下來的一次性步驟(搬遷原主機角色):' + [Environment]::NewLine + [Environment]::NewLine +
             '1. 按「開始當主機」開服' + [Environment]::NewLine +
             '2. 原本 co-op 的主機進遊戲連線,建立一個新角色,然後下線' + [Environment]::NewLine +
             '3. 按「收工上傳」' + [Environment]::NewLine +
             '4. 按「完成角色搬遷」——等級、背包、帕魯、科技、圖鑑、外觀全部自動搬回' + [Environment]::NewLine + [Environment]::NewLine +
             '其他玩家不用做任何事,角色自動延續。'),
            'PalRelay - 匯入完成', 'OK', 'Information')
    } catch {
        Show-Error $_.Exception.Message
    }
}

# ---------- 事件 ----------
$ActionBtn.Add_Click({ if ($Script:GuiHosting) { Gui-Stop $false } else { Gui-Start } })
$RefreshBtn.Add_Click({ $Script:GuiOptCache.Clear(); Refresh-Worlds; Refresh-Status })
$NewWorldBtn.Add_Click({
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('新世界的名字(例如:建築世界):', 'PalRelay - 新世界', '')
    if (-not $name) { return }
    if ($name -match '[\\/:*?"<>|]') { Show-Error '名字不能包含 \ / : * ? " < > |'; return }
    if (-not $WorldCombo.Items.Contains($name)) { [void]$WorldCombo.Items.Add($name) }
    $WorldCombo.SelectedItem = $name
    Gui-Log ('已選擇新世界「' + $name + '」,按「開始當主機」即建立。')
})
$ImportBtn.Add_Click({ Gui-Import })
$WorldCombo.Add_SelectionChanged({ Refresh-Status })
$CopyBtn.Add_Click({ try { Set-Clipboard -Value $ConnectBox.Text; Gui-Log ('已複製連線位址:' + $ConnectBox.Text) } catch {} })
$FixhostBtn.Add_Click({
    $Script:WorldName = [string]$WorldCombo.SelectedItem
    if (-not (Confirm-Prompt ('對世界「' + $Script:WorldName + '」執行原主機角色搬遷?(需要原主機已連線建立過新角色)') $true)) { return }
    try {
        $code = Cmd-Fixhost
        if ($code -eq 0) { Gui-Log '角色搬遷流程結束。' } else { Gui-Log ('角色搬遷未完成(代碼 ' + $code + '),請看上方訊息。') }
    } catch { Show-Error $_.Exception.Message }
})
$FixmapBtn.Add_Click({
    $Script:WorldName = [string]$WorldCombo.SelectedItem
    try {
        $code = Cmd-Fixmap
        if ($code -eq 0) { Gui-Log '地圖檢查/修復完成。' }
    } catch { Show-Error $_.Exception.Message }
})
$OpenFolderBtn.Add_Click({
    $p = Get-SaveRoot
    if (Test-Path $p) { Start-Process explorer.exe $p } else { Show-Error ('找不到資料夾:' + $p) }
})
$HelpBtn.Add_Click({ Start-Process 'https://github.com/Lother13501350/palrelay#readme' })

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
    $r = [Windows.MessageBox]::Show(
        ('還沒完成設定。要現在執行安裝精靈(setup.cmd)嗎?' + [Environment]::NewLine + $_.Exception.Message),
        'PalRelay', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
    if ($r -eq [Windows.MessageBoxResult]::Yes) {
        Start-Process (Join-Path $guiDir 'setup.cmd')
    }
    exit 1
}
try { Ensure-CloudLayout } catch { Gui-Log ('雲端檢查失敗: ' + $_.Exception.Message) }
$ToolVerText.Text = 'PalRelay v' + $Script:ToolVersion
Refresh-Worlds
Refresh-Status
Gui-Log ('PalRelay v' + $Script:ToolVersion + ' 已就緒。')
$timer.Start()

if ($env:PALRELAY_GUI_TEST -eq '1') {
    Write-Host 'GUI OK (test mode, window not shown)'
    exit 0
}
[void]$window.ShowDialog()
