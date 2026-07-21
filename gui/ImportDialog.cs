using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace PalRelay.Gui;

/// <summary>Pick a local co-op world and name it for the cloud.</summary>
public sealed class ImportDialog : Window
{
    private readonly ListBox _list = new();
    private readonly TextBox _nameBox = new();
    private readonly List<string> _paths = new();

    public string? SelectedPath { get; private set; }
    public string WorldName { get; private set; } = "";

    public ImportDialog(JsonArray worlds)
    {
        Title = "匯入既有世界";
        Width = 560; Height = 460;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = (Brush)Application.Current.Resources["BgBrush"];

        var grid = new Grid { Margin = new Thickness(14) };
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var head = new TextBlock
        {
            Text = "選擇要搬進雲端的世界(原存檔不會被更動):",
            Foreground = (Brush)Application.Current.Resources["MutedBrush"],
            Margin = new Thickness(0, 0, 0, 8),
        };
        Grid.SetRow(head, 0);
        grid.Children.Add(head);

        _list.Background = (Brush)Application.Current.Resources["CardBrush"];
        _list.Foreground = (Brush)Application.Current.Resources["TextBrush"];
        _list.BorderThickness = new Thickness(0);
        _list.FontSize = 13;
        foreach (var w in worlds)
        {
            var name = w?["name"]?.GetValue<string?>() ?? "(讀不到名稱)";
            var modified = w?["modified"]?.GetValue<string>() ?? "";
            if (DateTime.TryParse(modified, null, System.Globalization.DateTimeStyles.RoundtripKind, out var dt))
                modified = dt.ToLocalTime().ToString("yyyy/MM/dd HH:mm");
            _list.Items.Add($"{name}    最後遊玩 {modified}");
            _paths.Add(w?["path"]?.GetValue<string>() ?? "");
        }
        _list.SelectedIndex = 0;
        Grid.SetRow(_list, 1);
        grid.Children.Add(_list);

        var namePanel = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
        var nameLabel = new TextBlock
        {
            Text = "雲端世界名稱:", VerticalAlignment = VerticalAlignment.Center,
            Foreground = (Brush)Application.Current.Resources["MutedBrush"], Margin = new Thickness(0, 0, 8, 0),
        };
        DockPanel.SetDock(nameLabel, Dock.Left);
        namePanel.Children.Add(nameLabel);
        _nameBox.FontSize = 13;
        _nameBox.Padding = new Thickness(4);
        namePanel.Children.Add(_nameBox);
        Grid.SetRow(namePanel, 2);
        grid.Children.Add(namePanel);

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 12, 0, 0),
        };
        var ok = new Button { Content = "匯入", Width = 90, Height = 30, Margin = new Thickness(0, 0, 8, 0),
                              Background = new SolidColorBrush(Color.FromRgb(0x3f, 0xa8, 0x60)), Foreground = Brushes.White };
        var cancel = new Button { Content = "取消", Width = 90, Height = 30 };
        ok.Click += (_, _) =>
        {
            if (_list.SelectedIndex < 0) return;
            var name = _nameBox.Text.Trim();
            if (name.Length == 0) { MessageBox.Show("請輸入雲端世界名稱", "PalRelay"); return; }
            if (name.IndexOfAny(['\\', '/', ':', '*', '?', '"', '<', '>', '|']) >= 0)
            { MessageBox.Show("名稱不能包含 \\ / : * ? \" < > |", "PalRelay"); return; }
            SelectedPath = _paths[_list.SelectedIndex];
            WorldName = name;
            DialogResult = true;
        };
        cancel.Click += (_, _) => DialogResult = false;
        buttons.Children.Add(ok);
        buttons.Children.Add(cancel);
        Grid.SetRow(buttons, 3);
        grid.Children.Add(buttons);

        Content = grid;
    }
}
