using System.Text;
using System.Text.RegularExpressions;

namespace SwiftpointBatteryPlugin;

/// <summary>
/// Incrementally tails the Swiftpoint X1 Control Panel log and tracks the
/// latest battery report and which Z3 connection is active.
///
/// Requires VerboseLogging=true in X1's settings.ini — without it X1 logs
/// "getBatteryStatus" calls but never the values.
///
/// Relevant log lines (X1 3.1.3.1):
///   ... - Start "Swiftpoint X1 Control Panel" "3.1.3.1"
///   ... - X1DeviceManager: "Z3 (SwiftLink)" Connected
///   ... - X1DeviceManager: "Z3 (USB)" Disconnected
///   ... - ZeeInterface: Battery Report Received: 93 % Charging
/// </summary>
public sealed class Z3LogParser
{
    private static readonly Regex TimestampRx = new(
        @"^(?<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3})", RegexOptions.Compiled);
    private static readonly Regex DeviceRx = new(
        @"X1DeviceManager: ""(?<dev>[^""]+)"" (?<ev>Connected|Disconnected)\s*$", RegexOptions.Compiled);
    private static readonly Regex BatteryRx = new(
        @"Battery Report Received: (?<pct>\d{1,3}) % (?<state>\w+)", RegexOptions.Compiled);
    private static readonly Regex ProfileRx = new(
        @"Switching to\s+""(?<p>[^""]*)""", RegexOptions.Compiled);
    private static readonly Regex DeviceNameRx = new(
        @"^(?<model>.+?) \((?<conn>[^)]+)\)$", RegexOptions.Compiled);

    private static readonly byte[] StartMarker =
        Encoding.ASCII.GetBytes("Start \"Swiftpoint X1 Control Panel\"");

    private const int  ChunkSize      = 256 * 1024;
    private const long MaxInitialScan = 32L * 1024 * 1024;  // don't read more than 32 MB back on first load
    private const long MaxIncremental = 4L * 1024 * 1024;   // if more than this appeared since last poll, skip ahead

    /// <summary>A status flip on the same connection must stand this long before it's shown (filters one-off glitches).</summary>
    public static readonly TimeSpan StateHold = TimeSpan.FromSeconds(15);

    private readonly string _path;
    private long _offset = -1;

    // Connected mouse devices (receiver excluded), most recent last
    private readonly List<string> _connected = new();

    // Raw latest report
    private string?   _rawState;
    private DateTime  _rawStateTime;
    private string?   _rawStateConn;

    // Debounced state
    private string? _shownState;
    private string? _shownStateConn;

    public int?      Percentage     { get; private set; }
    public DateTime? LastReportTime { get; private set; }
    public string?   LastModel      { get; private set; }

    /// <summary>Profile X1 last switched to since it started (null until the first switch is logged).</summary>
    public string?   ActiveProfile  { get; private set; }

    public Z3LogParser(string path) => _path = path;

    /// <summary>Active connection ("SwiftLink", "USB", "Bluetooth"…) or null if no Z3 is connected.</summary>
    public string? Connection
    {
        get
        {
            if (_connected.Count == 0) return null;
            var m = DeviceNameRx.Match(_connected[^1]);
            return m.Success ? m.Groups["conn"].Value : _connected[^1];
        }
    }

    public bool IsConnected => _connected.Count > 0;

    /// <summary>Debounced battery state word from X1 ("Charging", "Discharging", …).</summary>
    public string? State => _shownState;

    public bool HasBatteryData => Percentage.HasValue;

    /// <summary>Reads anything new in the log. Call periodically.</summary>
    public void Poll(DateTime now)
    {
        using var fs = new FileStream(_path, FileMode.Open, FileAccess.Read,
                                      FileShare.ReadWrite | FileShare.Delete);
        long len = fs.Length;

        if (_offset < 0 || len < _offset)
        {
            // First run, or the log was truncated/replaced: rebuild state from the last X1 start.
            Reset();
            long from = FindScanStart(fs, len);
            _offset = ReadForward(fs, from, len);
        }
        else if (len > _offset)
        {
            long from = len - _offset > MaxIncremental ? SkipToLineStart(fs, len - MaxIncremental, len) : _offset;
            _offset = ReadForward(fs, from, len);
        }

        UpdateShownState(now);
    }

    private void Reset()
    {
        _connected.Clear();
        ActiveProfile = null;
        _rawState = _shownState = _rawStateConn = _shownStateConn = null;
        Percentage = null;
        LastReportTime = null;
    }

    private void UpdateShownState(DateTime now)
    {
        if (_rawState == null || _rawState == _shownState) return;

        bool firstValue      = _shownState == null;
        bool connChanged     = _rawStateConn != _shownStateConn;
        bool heldLongEnough  = now - _rawStateTime >= StateHold;

        if (firstValue || connChanged || heldLongEnough)
        {
            _shownState     = _rawState;
            _shownStateConn = _rawStateConn;
        }
    }

    // ---- file reading -------------------------------------------------------

    /// <summary>Walks backwards in chunks to find the most recent X1 "Start" line.</summary>
    private static long FindScanStart(FileStream fs, long len)
    {
        long floor = Math.Max(0, len - MaxInitialScan);
        long end = len;
        var buf = new byte[ChunkSize + StartMarker.Length];

        while (end > floor)
        {
            long start = Math.Max(floor, end - ChunkSize);
            int count = (int)Math.Min(buf.Length, len - start);
            fs.Seek(start, SeekOrigin.Begin);
            fs.ReadExactly(buf, 0, count);

            int idx = buf.AsSpan(0, count).LastIndexOf(StartMarker);
            if (idx >= 0)
            {
                int lineStart = buf.AsSpan(0, idx).LastIndexOf((byte)'\n') + 1;
                if (lineStart > 0 || start == 0) return start + lineStart;
                // Line began before this chunk; step back to the previous newline.
                return SkipToLineStartBackward(fs, start);
            }
            end = start;
        }
        return floor == 0 ? 0 : SkipToLineStart(fs, floor, len);
    }

    private static long SkipToLineStartBackward(FileStream fs, long pos)
    {
        var b = new byte[1];
        while (pos > 0)
        {
            fs.Seek(pos - 1, SeekOrigin.Begin);
            fs.ReadExactly(b, 0, 1);
            if (b[0] == (byte)'\n') return pos;
            pos--;
        }
        return 0;
    }

    private static long SkipToLineStart(FileStream fs, long pos, long len)
    {
        fs.Seek(pos, SeekOrigin.Begin);
        int b;
        while (pos < len && (b = fs.ReadByte()) != -1)
        {
            pos++;
            if (b == '\n') return pos;
        }
        return pos;
    }

    /// <summary>Parses complete lines in [from, len). Returns the offset just past the last newline.</summary>
    private long ReadForward(FileStream fs, long from, long len)
    {
        if (from >= len) return from;
        var buf = new byte[len - from];
        fs.Seek(from, SeekOrigin.Begin);
        fs.ReadExactly(buf, 0, buf.Length);

        int lastNl = Array.LastIndexOf(buf, (byte)'\n');
        if (lastNl < 0) return from;  // no complete line yet

        var text = Encoding.UTF8.GetString(buf, 0, lastNl + 1);
        foreach (var raw in text.Split('\n'))
            ProcessLine(raw.TrimEnd('\r'));

        return from + lastNl + 1;
    }

    // ---- line parsing -------------------------------------------------------

    internal void ProcessLine(string line)
    {
        if (line.Length == 0) return;

        if (line.Contains("Start \"Swiftpoint X1 Control Panel\""))
        {
            _connected.Clear();  // X1 restarted: it will re-announce connected devices
            ActiveProfile = null;
            return;
        }

        var dm = DeviceRx.Match(line);
        if (dm.Success)
        {
            var dev = dm.Groups["dev"].Value;
            if (dev.Contains("Receiver", StringComparison.OrdinalIgnoreCase)) return;

            _connected.Remove(dev);
            if (dm.Groups["ev"].Value == "Connected")
            {
                _connected.Add(dev);
                var nm = DeviceNameRx.Match(dev);
                LastModel = nm.Success ? nm.Groups["model"].Value : dev;
            }
            return;
        }

        var pm = ProfileRx.Match(line);
        if (pm.Success)
        {
            ActiveProfile = pm.Groups["p"].Value;
            return;
        }

        var bm = BatteryRx.Match(line);
        if (bm.Success)
        {
            var ts = ParseTimestamp(line) ?? DateTime.Now;
            Percentage     = Math.Clamp(int.Parse(bm.Groups["pct"].Value), 0, 100);
            LastReportTime = ts;
            _rawState      = bm.Groups["state"].Value;
            _rawStateTime  = ts;
            _rawStateConn  = Connection;
        }
    }

    private static DateTime? ParseTimestamp(string line)
    {
        var m = TimestampRx.Match(line);
        return m.Success && DateTime.TryParse(m.Groups["ts"].Value, out var dt) ? dt : null;
    }
}
