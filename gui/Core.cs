using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json.Nodes;

namespace PalRelay.Gui;

/// <summary>
/// Thin backend: state-changing operations go through palrelay.ps1 (the single
/// source of truth for the relay protocol, invoked with -Json); read-only
/// status queries talk to rclone directly for snappy refreshes.
/// </summary>
public static class Core
{
    public static string ToolDir { get; private set; } = "";
    public static JsonNode? Config { get; private set; }

    public static string? ResolveToolDir()
    {
        // exe either sits next to palrelay.ps1 or inside a subfolder of it
        var candidates = new[]
        {
            AppContext.BaseDirectory,
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..")),
        };
        foreach (var c in candidates)
        {
            if (File.Exists(Path.Combine(c, "palrelay.ps1")))
            {
                ToolDir = c;
                return c;
            }
        }
        return null;
    }

    public static void LoadConfig()
    {
        var p = Path.Combine(ToolDir, "config.json");
        Config = File.Exists(p) ? JsonNode.Parse(File.ReadAllText(p, Encoding.UTF8)) : null;
    }

    public static string RclonePath => Config?["rclonePath"]?.GetValue<string>() is { Length: > 0 } v ? v : "rclone";
    public static string Remote => (Config?["remote"]?.GetValue<string>() ?? "gdrive:").TrimEnd('/');
    public static string ServerDir => Config?["serverDir"]?.GetValue<string>() ?? "";
    public static int ServerPort => Config?["serverPort"]?.GetValue<int?>() ?? 8211;
    public static double HeartbeatMinutes => Config?["heartbeatMinutes"]?.GetValue<double?>() ?? 5;

    public static string? RcloneConfigPath
    {
        get
        {
            var rc = Config?["rcloneConfig"]?.GetValue<string>();
            if (string.IsNullOrWhiteSpace(rc)) return null;
            return Path.IsPathRooted(rc) ? rc : Path.Combine(ToolDir, rc);
        }
    }

    // ------------------------------------------------------------- rclone ---

    private static async Task<(int Code, string StdOut)> RunRcloneAsync(CancellationToken ct, params string[] args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = RclonePath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        if (RcloneConfigPath is { } cfg)
        {
            psi.ArgumentList.Add("--config");
            psi.ArgumentList.Add(cfg);
        }
        foreach (var a in args) psi.ArgumentList.Add(a);

        using var proc = Process.Start(psi)!;
        var stdout = proc.StandardOutput.ReadToEndAsync(ct);
        var stderr = proc.StandardError.ReadToEndAsync(ct);
        await proc.WaitForExitAsync(ct);
        return (proc.ExitCode, await stdout);
    }

    public static async Task<JsonNode?> CatJsonAsync(string remotePath, CancellationToken ct = default)
    {
        try
        {
            var (code, output) = await RunRcloneAsync(ct, "cat", $"{Remote}/{remotePath}");
            if (code != 0 || string.IsNullOrWhiteSpace(output)) return null;
            return JsonNode.Parse(output);
        }
        catch { return null; }
    }

    public static async Task<List<string>> ListWorldsAsync(CancellationToken ct = default)
    {
        var result = new List<string>();
        try
        {
            var (code, output) = await RunRcloneAsync(ct, "lsjson", "--dirs-only", $"{Remote}/worlds");
            if (code != 0 || string.IsNullOrWhiteSpace(output)) return result;
            if (JsonNode.Parse(output) is JsonArray arr)
                foreach (var it in arr)
                    if (it?["Name"]?.GetValue<string>() is { Length: > 0 } n)
                        result.Add(n);
        }
        catch { }
        return result;
    }

    // ---------------------------------------------------------- palrelay ----

    public sealed record CliResult(int Code, JsonNode? Json);

    public static async Task<CliResult> RunCliAsync(IEnumerable<string> args, Action<string>? log = null, CancellationToken ct = default)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = ToolDir,
        };
        foreach (var a in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                  "-File", Path.Combine(ToolDir, "palrelay.ps1") })
            psi.ArgumentList.Add(a);
        foreach (var a in args) psi.ArgumentList.Add(a);
        psi.ArgumentList.Add("-Json");

        using var proc = Process.Start(psi)!;
        string? jsonLine = null;

        var outTask = Task.Run(async () =>
        {
            while (await proc.StandardOutput.ReadLineAsync(ct) is { } line)
                if (line.StartsWith('{')) jsonLine = line;
        }, ct);
        var errTask = Task.Run(async () =>
        {
            while (await proc.StandardError.ReadLineAsync(ct) is { } line)
                if (log is not null && line.Length > 0) log(line);
        }, ct);

        await proc.WaitForExitAsync(ct);
        await Task.WhenAll(outTask, errTask);

        JsonNode? node = null;
        if (jsonLine is not null)
            try { node = JsonNode.Parse(jsonLine); } catch { }
        return new CliResult(proc.ExitCode, node);
    }

    public static bool IsServerProcessRunning()
        => Process.GetProcesses().Any(p =>
        {
            try { return p.ProcessName.StartsWith("PalServer", StringComparison.OrdinalIgnoreCase); }
            catch { return false; }
        });

    // ------------------------------------------------------- world settings --

    public static readonly (string Key, string Label)[] SettingLabels =
    {
        ("Difficulty", "難度"),
        ("ExpRate", "經驗值倍率"),
        ("WorkSpeedRate", "工作速度倍率"),
        ("PalCaptureRate", "捕捉倍率"),
        ("PalEggDefaultHatchingTime", "孵蛋時間(小時)"),
        ("CollectionDropRate", "採集掉落倍率"),
        ("EnemyDropItemRate", "擊殺掉落倍率"),
        ("PlayerDamageRateDefense", "玩家受傷倍率"),
        ("PlayerStomachDecreaceRate", "飽食消耗倍率"),
        ("PlayerStaminaDecreaceRate", "耐力消耗倍率"),
        ("DayTimeSpeedRate", "白天流速"),
        ("NightTimeSpeedRate", "夜晚流速"),
        ("DeathPenalty", "死亡懲罰"),
        ("BaseCampWorkerMaxNum", "基地帕魯上限"),
    };

    public static readonly Dictionary<string, string> DeathPenaltyNames = new()
    {
        ["None"] = "無", ["Item"] = "掉道具", ["ItemAndEquipment"] = "掉道具與裝備", ["All"] = "全部掉落",
    };

    public static string FormatSettings(JsonNode? options)
    {
        var ov = options?["optionOverrides"];
        if (ov is not JsonObject obj) return "此世界沒有自訂設定(使用預設值),或以 v0.5 之前的版本匯入。";
        var parts = new List<string>();
        var shown = new HashSet<string>();
        foreach (var (key, label) in SettingLabels)
        {
            if (obj[key] is not { } valNode) continue;
            var val = valNode.GetValue<string>();
            if (double.TryParse(val, out var num)) val = num.ToString("0.##");
            if (key == "DeathPenalty" && DeathPenaltyNames.TryGetValue(val, out var friendly)) val = friendly;
            parts.Add($"{label}:{val}");
            shown.Add(key);
        }
        var extra = obj.Count - shown.Count;
        var text = string.Join("   ", parts);
        if (extra > 0) text += $"   (其他 {extra} 項)";
        return text.Length > 0 ? text : "(全部使用預設值)";
    }
}
