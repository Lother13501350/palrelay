using System.Diagnostics;
using System.IO;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace PalRelay.Gui;

public partial class MainWindow : Window
{
    private bool _hosting;
    private bool _busy;
    private bool _refreshing;
    private string World => WorldCombo.SelectedItem as string ?? "main";

    private readonly DispatcherTimer _statusTimer = new() { Interval = TimeSpan.FromSeconds(15) };
    private readonly DispatcherTimer _heartbeatTimer = new();
    private readonly DispatcherTimer _watchTimer = new() { Interval = TimeSpan.FromSeconds(5) };
    private readonly Dictionary<string, JsonNode?> _optionsCache = new();

    public MainWindow(string toolDir)
    {
        InitializeComponent();
        Core.LoadConfig();
        _heartbeatTimer.Interval = TimeSpan.FromMinutes(Math.Max(1, Core.HeartbeatMinutes));
        _statusTimer.Tick += async (_, _) => { if (!_hosting && !_busy) await RefreshStatusAsync(); };
        _heartbeatTimer.Tick += async (_, _) => await HeartbeatAsync();
        _watchTimer.Tick += async (_, _) => await WatchServerAsync();
        ToolVerText.Text = "PalRelay GUI v0.6.0";
        Loaded += async (_, _) =>
        {
            Log("PalRelay 已就緒。");
            await RefreshWorldsAsync();
            await RefreshStatusAsync();
            _statusTimer.Start();
        };
        Closing += (_, e) =>
        {
            if (_hosting &&
                MessageBox.Show("伺服器還在運作,直接關閉將不會上傳進度(之後開服會自動補上傳)。確定要關閉?",
                    "PalRelay", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
                e.Cancel = true;
        };
    }

    private void Log(string msg)
    {
        var line = msg;
        foreach (var (prefix, replace) in new[] { ("[info] ", ""), ("[warn] ", "警告: "), ("[error] ", "錯誤: ") })
            if (line.StartsWith(prefix)) { line = replace + line[prefix.Length..]; break; }
        LogBox.AppendText($"[{DateTime.Now:HH:mm:ss}] {line}\r\n");
        LogBox.ScrollToEnd();
    }

    private void LogFromCli(string msg) => Dispatcher.Invoke(() => Log(msg));

    private async Task<Core.CliResult> CliAsync(params string[] args)
        => await Core.RunCliAsync(args, LogFromCli);

    private void SetBusy(bool busy)
    {
        _busy = busy;
        foreach (var b in new Control[] { ActionBtn, ImportBtn, FixhostBtn, FixmapBtn, NewWorldBtn, RefreshBtn, WorldCombo })
            b.IsEnabled = !busy && (!_hosting || b == ActionBtn);
        if (!busy && !_hosting)
            foreach (var b in new Control[] { ImportBtn, FixhostBtn, FixmapBtn, NewWorldBtn, RefreshBtn, WorldCombo })
                b.IsEnabled = true;
    }

    // ------------------------------------------------------------ refresh ---

    private async Task RefreshWorldsAsync()
    {
        var current = WorldCombo.SelectedItem as string;
        var worlds = await Core.ListWorldsAsync();
        if (worlds.Count == 0) worlds.Add("main");
        WorldCombo.ItemsSource = worlds;
        var pick = current is not null && worlds.Contains(current) ? current : worlds[0];
        WorldCombo.SelectedItem = pick;
    }

    private async Task RefreshStatusAsync()
    {
        if (_refreshing || _hosting) return;
        _refreshing = true;
        try
        {
            var world = World;
            var lockTask = Core.CatJsonAsync($"worlds/{world}/lock.json");
            var latestTask = Core.CatJsonAsync($"worlds/{world}/latest.json");
            if (!_optionsCache.ContainsKey(world))
                _optionsCache[world] = await Core.CatJsonAsync($"worlds/{world}/options.json");
            var lockJson = await lockTask;
            var latest = await latestTask;
            if (world != World) return; // selection changed mid-flight

            if (lockJson is not null)
            {
                var holder = lockJson["holder"]?.GetValue<string>() ?? "?";
                var hbRaw = lockJson["heartbeatUtc"]?.GetValue<string>();
                var stale = DateTime.TryParse(hbRaw, null, System.Globalization.DateTimeStyles.RoundtripKind, out var hb)
                            && (DateTime.UtcNow - hb.ToUniversalTime()).TotalMinutes > 20;
                if (stale)
                {
                    StatusText.Text = $"狀態:{holder} 的鎖已過期(可能當機),可接管";
                    StatusText.Foreground = Brushes.Orange;
                }
                else
                {
                    StatusText.Text = $"狀態:{holder} 正在開服中";
                    StatusText.Foreground = (Brush)FindResource("BusyBrush");
                    var ip = lockJson["hostIp"]?.GetValue<string>();
                    if (!string.IsNullOrEmpty(ip))
                    {
                        ConnectBox.Text = $"{ip}:{lockJson["serverPort"]?.GetValue<int?>() ?? Core.ServerPort}";
                        CopyBtn.IsEnabled = true;
                    }
                }
            }
            else
            {
                StatusText.Text = "狀態:世界空閒,可以開服!";
                StatusText.Foreground = (Brush)FindResource("GoodBrush");
                ConnectBox.Text = "(開服後這裡會顯示朋友要輸入的連線位址)";
                CopyBtn.IsEnabled = false;
            }

            if (latest is not null)
            {
                var mb = (latest["sizeBytes"]?.GetValue<double?>() ?? 0) / 1024 / 1024;
                var when = latest["uploadedUtc"]?.GetValue<string>() ?? "";
                if (DateTime.TryParse(when, null, System.Globalization.DateTimeStyles.RoundtripKind, out var dt))
                    when = dt.ToLocalTime().ToString("MM/dd HH:mm");
                VersionText.Text = $"最新存檔:v{latest["version"]}({mb:0.#} MB)由 {latest["uploadedBy"]} 於 {when} 上傳";
                DetailText.Text = $"世界 ID:{latest["worldGuid"]}";
            }
            else
            {
                VersionText.Text = "最新存檔:還沒有(第一次開服會自動建立新世界)";
                DetailText.Text = "";
            }

            SettingsText.Text = Core.FormatSettings(_optionsCache[world]);
        }
        catch (Exception ex)
        {
            StatusText.Text = "狀態讀取失敗:" + ex.Message;
            StatusText.Foreground = Brushes.Orange;
        }
        finally { _refreshing = false; }
    }

    // ------------------------------------------------------------ hosting ---

    private async void ActionBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        if (_hosting) await EndSessionAsync();
        else await BeginSessionAsync(force: false);
    }

    private async Task BeginSessionAsync(bool force)
    {
        SetBusy(true);
        ActionBtn.Content = "啟動中...";
        try
        {
            var args = new List<string> { "session-begin", World };
            if (force) args.Add("-Force");
            var r = await CliAsync(args.ToArray());
            var ok = r.Json?["ok"]?.GetValue<bool>() ?? false;
            if (!ok)
            {
                var reason = r.Json?["reason"]?.GetValue<string>() ?? "unknown";
                switch (reason)
                {
                    case "locked":
                        MessageBox.Show($"{r.Json?["holder"]} 正在開這個世界,同時只能有一個人開服。", "PalRelay");
                        break;
                    case "stale-lock":
                        if (MessageBox.Show($"{r.Json?["holder"]} 的鎖已過期(可能當機)。接管會失去他沒上傳的進度,確定接管?",
                                "PalRelay", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                        {
                            SetBusy(false);
                            await BeginSessionAsync(force: true);
                            return;
                        }
                        break;
                    default:
                        MessageBox.Show("開服失敗:" + (r.Json?["error"]?.GetValue<string>() ?? reason), "PalRelay");
                        break;
                }
                return;
            }

            _hosting = true;
            var ip = r.Json?["hostIp"]?.GetValue<string>();
            var port = r.Json?["serverPort"]?.GetValue<int?>() ?? Core.ServerPort;
            StatusText.Text = $"狀態:你正在開服(世界:{World})";
            StatusText.Foreground = (Brush)FindResource("BusyBrush");
            if (!string.IsNullOrEmpty(ip))
            {
                ConnectBox.Text = $"{ip}:{port}";
                CopyBtn.IsEnabled = true;
                if (r.Json?["hostIpSource"]?.GetValue<string>() == "public")
                    Log("注意:這是對外 IP,路由器必須開 UDP 8211 轉發;全員安裝 Tailscale 可免設定。");
            }
            else ConnectBox.Text = "(抓不到連線位址:建議安裝 Tailscale)";
            ActionBtn.Content = "收工上傳";
            ActionBtn.Background = (Brush)FindResource("BusyBrush");
            _heartbeatTimer.Start();
            _watchTimer.Start();
            Log("伺服器啟動中,朋友稍等一下就能連線。收工時按「收工上傳」。");
        }
        finally
        {
            if (!_hosting) ActionBtn.Content = "開始當主機";
            SetBusy(false);
        }
    }

    private async Task EndSessionAsync()
    {
        SetBusy(true);
        ActionBtn.Content = "上傳中...";
        _heartbeatTimer.Stop();
        _watchTimer.Stop();
        try
        {
            var r = await CliAsync("session-end", World);
            if (r.Json?["ok"]?.GetValue<bool>() ?? false)
            {
                _hosting = false;
                ActionBtn.Content = "開始當主機";
                ActionBtn.Background = new SolidColorBrush(Color.FromRgb(0x3f, 0xa8, 0x60));
                Log($"完成!存檔 v{r.Json?["version"]} 已上傳,世界已釋放給下一位。");
                await RefreshStatusAsync();
            }
            else
            {
                ActionBtn.Content = "收工上傳";
                _heartbeatTimer.Start();
                _watchTimer.Start();
                MessageBox.Show("上傳失敗,鎖已保留(保護)。排除問題後再按一次「收工上傳」。\r\n" +
                                (r.Json?["error"]?.GetValue<string>() ?? ""), "PalRelay");
            }
        }
        finally { SetBusy(false); }
    }

    private async Task HeartbeatAsync()
    {
        if (!_hosting) return;
        var r = await CliAsync("session-heartbeat", World);
        if (!(r.Json?["ok"]?.GetValue<bool>() ?? false))
            Log("警告:心跳失敗(" + (r.Json?["reason"]?.GetValue<string>() ?? "?") + "),請確認網路與鎖狀態。");
    }

    private async Task WatchServerAsync()
    {
        if (!_hosting || _busy) return;
        if (Core.IsServerProcessRunning()) return;
        _watchTimer.Stop();
        Log("伺服器自己結束了。");
        if (MessageBox.Show("伺服器已停止。要把目前的本機存檔上傳嗎?(建議:是)",
                "PalRelay", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
            await EndSessionAsync();
        else
        {
            _hosting = false;
            _heartbeatTimer.Stop();
            ActionBtn.Content = "開始當主機";
            ActionBtn.Background = new SolidColorBrush(Color.FromRgb(0x3f, 0xa8, 0x60));
            Log("警告:進度未上傳,雲端鎖保留;下次開服會自動補上傳。");
            SetBusy(false);
        }
    }

    // ------------------------------------------------------------- actions --

    private async void RefreshBtn_Click(object sender, RoutedEventArgs e)
    {
        _optionsCache.Clear();
        await RefreshWorldsAsync();
        await RefreshStatusAsync();
    }

    private async void WorldCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
        => await RefreshStatusAsync();

    private void NewWorldBtn_Click(object sender, RoutedEventArgs e)
    {
        var name = Prompt("新世界的名字(例如:建築世界):");
        if (string.IsNullOrWhiteSpace(name)) return;
        if (name.IndexOfAny(['\\', '/', ':', '*', '?', '"', '<', '>', '|']) >= 0)
        {
            MessageBox.Show("名字不能包含 \\ / : * ? \" < > |", "PalRelay");
            return;
        }
        var items = (WorldCombo.ItemsSource as List<string>) ?? [];
        if (!items.Contains(name)) { items.Add(name); WorldCombo.ItemsSource = null; WorldCombo.ItemsSource = items; }
        WorldCombo.SelectedItem = name;
        Log($"已選擇新世界「{name}」,按「開始當主機」即建立。");
    }

    private async void ImportBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        SetBusy(true);
        try
        {
            Log("掃描本機 co-op 世界...");
            var r = await CliAsync("list-coop");
            var worlds = r.Json?["worlds"] as JsonArray;
            if (worlds is null || worlds.Count == 0)
            {
                MessageBox.Show("在這台電腦上找不到任何合作模式(co-op)世界。", "PalRelay");
                return;
            }
            var dlg = new ImportDialog(worlds) { Owner = this };
            if (dlg.ShowDialog() != true || dlg.SelectedPath is null) return;

            Log($"匯入「{dlg.WorldName}」中,請稍候...");
            var ri = await CliAsync("import", dlg.WorldName, "-Source", dlg.SelectedPath, "-Yes");
            if (ri.Json?["ok"]?.GetValue<bool>() ?? false)
            {
                await RefreshWorldsAsync();
                WorldCombo.SelectedItem = dlg.WorldName;
                MessageBox.Show(
                    "世界已上雲!接下來的一次性步驟(搬遷原主機角色):\r\n\r\n" +
                    "1. 按「開始當主機」開服\r\n" +
                    "2. 原本 co-op 的主機進遊戲連線,建立一個新角色,然後下線\r\n" +
                    "3. 按「收工上傳」\r\n" +
                    "4. 按「完成角色搬遷」——等級、背包、帕魯、科技、圖鑑、外觀全部自動搬回\r\n\r\n" +
                    "其他玩家不用做任何事,角色自動延續。",
                    "PalRelay - 匯入完成", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            else
                MessageBox.Show("匯入失敗:" + (ri.Json?["error"]?.GetValue<string>() ?? "請看紀錄"), "PalRelay");
        }
        finally { SetBusy(false); }
    }

    private async void FixhostBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        if (MessageBox.Show($"對世界「{World}」執行原主機角色搬遷?(需要原主機已連線建立過新角色)",
                "PalRelay", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        SetBusy(true);
        try
        {
            var r = await CliAsync("fixhost", World, "-Yes");
            var ok = r.Json?["ok"]?.GetValue<bool>() ?? false;
            if (!ok && r.Json?["reason"]?.GetValue<string>() == "ambiguous" && r.Json?["candidates"] is JsonArray cands)
            {
                var pick = Prompt("有多個候選角色檔,輸入原主機「剛建立」那個的編號:\r\n" +
                    string.Join("\r\n", cands.Select((c, i) => $"{i + 1}. {c}")));
                if (int.TryParse(pick, out var idx) && idx >= 1 && idx <= cands.Count)
                    r = await CliAsync("fixhost", World, "-Yes", "-NewGuid", cands[idx - 1]!.GetValue<string>());
                ok = r.Json?["ok"]?.GetValue<bool>() ?? false;
            }
            if (ok)
            {
                var v = r.Json?["verify"];
                Log($"搬遷完成並通過驗證:角色「{v?["nickname"]}」(Lv.{v?["level"]}),容器 {v?["containersFound"]}/{v?["containersExpected"]}。");
                MessageBox.Show("角色搬遷完成!下次開服,原主機連進去就是原本的角色。", "PalRelay");
            }
            else
                Log("角色搬遷未完成:" + (r.Json?["error"]?.GetValue<string>() ?? r.Json?["reason"]?.GetValue<string>() ?? "請看紀錄"));
        }
        finally { SetBusy(false); }
    }

    private async void FixmapBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        SetBusy(true);
        try
        {
            var r = await CliAsync("fixmap", World);
            if (r.Json?["ok"]?.GetValue<bool>() ?? false)
                Log((r.Json?["restored"]?.GetValue<bool>() ?? false) ? "地圖資料已還原!" : "地圖資料已是最佳狀態,不需還原。");
            else
                Log("修復地圖未完成:" + (r.Json?["error"]?.GetValue<string>() ?? "請先關閉遊戲再試"));
        }
        finally { SetBusy(false); }
    }

    private void OpenFolderBtn_Click(object sender, RoutedEventArgs e)
    {
        var p = Path.Combine(Core.ServerDir, "Pal", "Saved", "SaveGames", "0");
        if (Directory.Exists(p)) Process.Start(new ProcessStartInfo("explorer.exe", p) { UseShellExecute = true });
        else MessageBox.Show("找不到資料夾:" + p, "PalRelay");
    }

    private void HelpBtn_Click(object sender, RoutedEventArgs e)
        => Process.Start(new ProcessStartInfo("https://github.com/Lother13501350/palrelay#readme") { UseShellExecute = true });

    private void CopyBtn_Click(object sender, RoutedEventArgs e)
    {
        try { Clipboard.SetText(ConnectBox.Text); Log("已複製連線位址:" + ConnectBox.Text); } catch { }
    }

    private static string? Prompt(string message)
    {
        var dlg = new Window
        {
            Title = "PalRelay", Width = 420, Height = 200, WindowStartupLocation = WindowStartupLocation.CenterScreen,
            Background = (Brush)Application.Current.Resources["BgBrush"], ResizeMode = ResizeMode.NoResize,
        };
        var panel = new StackPanel { Margin = new Thickness(14) };
        panel.Children.Add(new TextBlock
        {
            Text = message, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10),
            Foreground = (Brush)Application.Current.Resources["TextBrush"],
        });
        var box = new TextBox { FontSize = 14, Padding = new Thickness(6) };
        panel.Children.Add(box);
        var ok = new Button { Content = "確定", Width = 90, Margin = new Thickness(0, 12, 0, 0), HorizontalAlignment = HorizontalAlignment.Right };
        string? result = null;
        ok.Click += (_, _) => { result = box.Text; dlg.Close(); };
        box.KeyDown += (_, ke) => { if (ke.Key == System.Windows.Input.Key.Enter) { result = box.Text; dlg.Close(); } };
        panel.Children.Add(ok);
        dlg.Content = panel;
        box.Focus();
        dlg.ShowDialog();
        return result;
    }
}
