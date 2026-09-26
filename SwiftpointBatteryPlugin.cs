using System.Diagnostics;
using System.IO.Pipes;
using InfoPanel.Plugins;

namespace SwiftpointBatteryPlugin;

/// <summary>
/// InfoPanel plugin that shows Swiftpoint Z3 battery level, charging state and
/// connection type by tailing the Swiftpoint X1 Control Panel log.
///
/// X1 has no API command for battery (X1 API v2 only covers profiles/DPI/RGB/OLED),
/// but with VerboseLogging=true it logs every battery report the mouse sends.
/// Polls every 3 seconds; only reads the bytes appended since the last poll.
/// </summary>
public class SwiftpointBatteryPlugin : BasePlugin
{
    // Sensors (ids/names mirror the Logitech plugin so panels can be built the same way)
    private readonly PluginText   _deviceName     = new("device_name",     "Device",     "Swiftpoint Z3");
    private readonly PluginSensor _batteryPct     = new("battery_pct",     "Battery",    0, "%");
    private readonly PluginText   _chargingText   = new("charging_text",   "Charging",   "Unknown");
    private readonly PluginText   _connectionText = new("connection_text", "Connection", "Unknown");
    private readonly PluginText   _profileText    = new("profile_text",    "Profile",    "Unknown");
    private readonly PluginText   _statusText     = new("status_text",     "Status",     "Starting...");

    private static readonly string LogPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Swiftpoint X1 Control Panel", "log.txt");

    private const string X1ProcessName = "Swiftpoint X1 Control Panel";

    private const string X1PipeName = "swiftpoint.x1.v2.command";

    private Z3LogParser? _parser;
    private string?  _apiProfile;
    private DateTime _lastApiQuery = DateTime.MinValue;
    private const int ApiQueryIntervalSeconds = 30;
    private DateTime _lastPoll = DateTime.MinValue;
    private const int PollIntervalSeconds = 3;

    public SwiftpointBatteryPlugin()
        : base("swiftpoint-battery", "Swiftpoint Battery", "Shows Swiftpoint Z3 battery via the X1 Control Panel log")
    {
    }

    public override string? ConfigFilePath => null;
    public override TimeSpan UpdateInterval => TimeSpan.FromSeconds(1);

    public override void Initialize()
    {
        _parser = new Z3LogParser(LogPath);
    }

    public override void Load(List<IPluginContainer> containers)
    {
        var container = new PluginContainer("Swiftpoint Z3");
        container.Entries.AddRange([_deviceName, _batteryPct, _chargingText, _connectionText, _profileText, _statusText]);
        containers.Add(container);
    }

    public override async Task UpdateAsync(CancellationToken ct)
    {
        Update();
        await Task.CompletedTask;
    }

    public override void Update()
    {
        if ((DateTime.UtcNow - _lastPoll).TotalSeconds < PollIntervalSeconds)
            return;

        _lastPoll = DateTime.UtcNow;

        try
        {
            if (!File.Exists(LogPath))
            {
                _statusText.Value = "X1 log not found";
                return;
            }

            _parser ??= new Z3LogParser(LogPath);
            _parser.Poll(DateTime.Now);

            bool x1Running = IsX1Running();

            if (_parser.LastModel is { } model)
                _deviceName.Value = $"Swiftpoint {model}";

            if (_parser.Percentage is int pct)
                _batteryPct.Value = pct;

            if (!x1Running)
                _connectionText.Value = "X1 not running";
            else
                _connectionText.Value = _parser.Connection ?? "Disconnected";

            _profileText.Value = x1Running ? (ResolveProfile() ?? "Unknown") : " ";

            _chargingText.Value = (x1Running && _parser.IsConnected) ? ChargingLabel(_parser.State, _parser.Connection, _parser.Percentage) : " ";

            if (!_parser.HasBatteryData)
                _statusText.Value = "No battery data - turn on VerboseLogging in X1 settings.ini";
            else if (!x1Running)
                _statusText.Value = "X1 Control Panel is not running";
            else
                _statusText.Value = $"Last report {_parser.LastReportTime:HH:mm:ss}";
        }
        catch (Exception ex)
        {
            _statusText.Value = $"Error: {ex.Message}";
        }
    }

    public override void Close() { }

    /// <summary>Matches the Logitech plugin: "Charging" while charging, blank otherwise.
    /// On the USB cable the Z3's reports flip between Charging and Discharging every
    /// 10-40 s (worst at 100% while it tops off), so the cable itself is treated as the
    /// source of truth: "Charging" below 100%, "Full" at 100%.
    /// Any other state word X1 reports is passed through as-is.</summary>
    private static string ChargingLabel(string? state, string? connection, int? pct)
    {
        if (string.Equals(connection, "USB", StringComparison.OrdinalIgnoreCase))
            return pct >= 100 ? "Full" : "Charging";

        return state switch
        {
            null => " ",
            _ when state.Equals("Charging", StringComparison.OrdinalIgnoreCase)    => "Charging",
            _ when state.Equals("Discharging", StringComparison.OrdinalIgnoreCase) => " ",
            _ => state,
        };
    }

    /// <summary>
    /// Active profile. The log records every switch ("Switching to  \"Game\""), but only
    /// after X1's first foreground-app check; until then, ask X1's API ("Profile Get"),
    /// at most every 30 s. The API is optional - if it's off, this just stays "Unknown".
    /// </summary>
    private string? ResolveProfile()
    {
        if (_parser?.ActiveProfile is { } fromLog)
        {
            _apiProfile = null;
            return fromLog;
        }

        if ((DateTime.UtcNow - _lastApiQuery).TotalSeconds >= ApiQueryIntervalSeconds)
        {
            _lastApiQuery = DateTime.UtcNow;
            _apiProfile = QueryX1Api("Profile Get") ?? _apiProfile;
        }
        return _apiProfile;
    }

    private static string? QueryX1Api(string command)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", X1PipeName, PipeDirection.InOut);
            pipe.Connect(500);
            using var writer = new StreamWriter(pipe, leaveOpen: true) { AutoFlush = true };
            using var reader = new StreamReader(pipe, leaveOpen: true);
            writer.WriteLine(command);
            var task = reader.ReadLineAsync();
            if (!task.Wait(1000)) return null;
            var reply = task.Result?.Trim();
            return string.IsNullOrEmpty(reply) || reply.StartsWith("ERR", StringComparison.OrdinalIgnoreCase) ? null : reply;
        }
        catch
        {
            return null;
        }
    }

    private static bool IsX1Running()
    {
        var procs = Process.GetProcessesByName(X1ProcessName);
        try { return procs.Length > 0; }
        finally { foreach (var p in procs) p.Dispose(); }
    }
}
