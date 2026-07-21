using System.IO;
using System.Windows;

namespace PalRelay.Gui;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        var toolDir = Core.ResolveToolDir();
        if (toolDir is null)
        {
            MessageBox.Show("找不到 palrelay.ps1。請把 PalRelay.exe 放在 PalRelay 資料夾裡執行。",
                "PalRelay", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(3);
            return;
        }

        if (Environment.GetEnvironmentVariable("PALRELAY_GUI_TEST") == "1")
        {
            // headless smoke test: construct the window, then exit cleanly
            _ = new MainWindow(toolDir);
            Shutdown(0);
            return;
        }

        if (!File.Exists(Path.Combine(toolDir, "config.json")))
        {
            var r = MessageBox.Show("還沒完成設定。要現在執行安裝精靈(setup.cmd)嗎?",
                "PalRelay", MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (r == MessageBoxResult.Yes)
            {
                var setup = Path.Combine(toolDir, "setup.cmd");
                if (File.Exists(setup))
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(setup) { UseShellExecute = true });
            }
            Shutdown(1);
            return;
        }

        var win = new MainWindow(toolDir);
        win.Show();
    }
}
