using System;
using System.Text.Json;
using cAlgo.API;

namespace cAlgo.Robots;

[Robot(AccessRights = AccessRights.FullAccess, AddIndicators = true)]
public class ZoneDetectorBot : Robot
{
    [Parameter("Relay Server URL", DefaultValue = "ws://178.104.242.7:25345")]
    public string ServerUrl { get; set; }

    [Parameter("API Key", DefaultValue = "YOUR_SECRET_API_KEY_HERE")]
    public string ApiKey { get; set; }

    [Parameter("Telegram Chat IDs", DefaultValue = "1003201387")]
    public string ChatIds { get; set; }

    private string[] _chatIds;
    private WebSocketClient _ws;
    private bool _stopping;

    protected override void OnStart()
    {
        _chatIds = ChatIds.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        Print($"[ZoneDetector] Starting. Relay: {ServerUrl} | ChatIds: {ChatIds}");
        Connect();
    }

    protected override void OnBar()
    {
        //if (IsBacktesting) return;

        if (_ws?.State != WebSocketClientState.Open)
        {
            Print("[ZoneDetector] Not connected, skipping bar");
            return;
        }

        var bar = Bars.Last(1);
        var msg = $"<b>ZoneDetector</b> - New {TimeFrame} candle on {SymbolName}\n" +
                  $"Time: {bar.OpenTime:yyyy-MM-dd HH:mm} UTC\n" +
                  $"O: {bar.Open}  H: {bar.High}  L: {bar.Low}  C: {bar.Close}";
        Send(msg);
    }

    protected override void OnStop()
    {
        _stopping = true;

        if (_ws?.State == WebSocketClientState.Open)
        {
            Send(
                $"<b>ZoneDetector</b> - Bot stopped\n" +
                $"Symbol: {SymbolName}  |  Timeframe: {TimeFrame}\n" +
                $"Time: {Server.Time:yyyy-MM-dd HH:mm} UTC"
            );
            _ws.Close(WebSocketClientCloseStatus.NormalClosure, string.Empty);
        }

        _ws?.Dispose();
    }

    private void Connect()
    {
        _ws?.Dispose();
        _ws = new WebSocketClient(new WebSocketClientOptions
        {
            KeepAliveInterval = TimeSpan.FromSeconds(30)
        });

        _ws.Connected += (_) =>
        {
            Print("[ZoneDetector] Connected");
            Send(
                $"<b>ZoneDetector</b> - Bot started\n" +
                $"Symbol: {SymbolName}  |  Timeframe: {TimeFrame}\n" +
                $"Time: {Server.Time:yyyy-MM-dd HH:mm} UTC"
            );
        };

        _ws.Disconnected += (_) =>
        {
            Print("[ZoneDetector] Disconnected");
            if (!_stopping)
            {
                Print("[ZoneDetector] Reconnecting in 5s...");
                Timer.Start(5);
            }
        };

        _ws.Connect(new Uri(ServerUrl.TrimEnd('/') + "/ws"));
    }

    protected override void OnTimer()
    {
        Timer.Stop();
        if (!_stopping)
            Connect();
    }

    private void Send(string message)
    {
        try
        {
            var payload = JsonSerializer.Serialize(new
            {
                apiKey = ApiKey,
                chatIds = _chatIds,
                message
            });
            _ws.Send(payload);
        }
        catch (Exception ex)
        {
            Print($"[ZoneDetector] Send failed: {ex.Message}");
        }
    }
}
