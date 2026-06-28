using System.Net.Http.Json;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var config = app.Configuration;
var botToken = config["TelegramBotToken"] ?? throw new InvalidOperationException("TelegramBotToken not configured");
var apiKey = config["ApiKey"] ?? throw new InvalidOperationException("ApiKey not configured");

var telegramClient = new HttpClient { BaseAddress = new Uri($"https://api.telegram.org/bot{botToken}/") };

app.UseWebSockets(new WebSocketOptions { KeepAliveInterval = Timeout.InfiniteTimeSpan });

app.MapGet("/health", async () =>
{
    try
    {
        var response = await telegramClient.GetAsync("getMe");
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();

        if (!response.IsSuccessStatusCode)
            return Results.Json(new { status = "degraded", telegram = "unreachable", detail = body.ToString(), time = DateTime.UtcNow }, statusCode: 503);

        var botName = body.GetProperty("result").GetProperty("username").GetString();
        return Results.Ok(new { status = "ok", telegram = "connected", bot = botName, time = DateTime.UtcNow });
    }
    catch (Exception ex)
    {
        return Results.Json(new { status = "degraded", telegram = "error", detail = ex.Message, time = DateTime.UtcNow }, statusCode: 503);
    }
});

app.Map("/ws", async (HttpContext context, ILogger<Program> logger) =>
{
    if (!context.WebSockets.IsWebSocketRequest)
    {
        context.Response.StatusCode = 400;
        return;
    }

    using var ws = await context.WebSockets.AcceptWebSocketAsync();
    logger.LogInformation("WebSocket client connected from {IP}", context.Connection.RemoteIpAddress);

    var buffer = new byte[65536];
    var firstMessage = true;

    while (ws.State == WebSocketState.Open)
    {
        var received = new StringBuilder();
        WebSocketReceiveResult result;

        do
        {
            result = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), CancellationToken.None);
            if (result.MessageType == WebSocketMessageType.Close) break;
            received.Append(Encoding.UTF8.GetString(buffer, 0, result.Count));
        }
        while (!result.EndOfMessage);

        if (result.MessageType == WebSocketMessageType.Close)
        {
            await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, string.Empty, CancellationToken.None);
            break;
        }

        WsRequest? request = null;
        try
        {
            request = JsonSerializer.Deserialize<WsRequest>(received.ToString(), new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        }
        catch
        {
            logger.LogWarning("Invalid JSON received");
            continue;
        }

        // Validate API key on first message only
        if (firstMessage)
        {
            if (request?.ApiKey != apiKey)
            {
                logger.LogWarning("WebSocket connection rejected: invalid API key");
                await ws.CloseAsync(WebSocketCloseStatus.PolicyViolation, "unauthorized", CancellationToken.None);
                return;
            }
            firstMessage = false;
        }

        if (request?.ChatIds is not { Length: > 0 } || string.IsNullOrWhiteSpace(request.Message))
        {
            logger.LogWarning("Missing chatIds or message");
            continue;
        }

        foreach (var chatId in request.ChatIds)
        {
            try
            {
                var payload = new { chat_id = chatId, text = request.Message, parse_mode = "HTML" };
                var response = await telegramClient.PostAsJsonAsync("sendMessage", payload);

                if (!response.IsSuccessStatusCode)
                {
                    var body = await response.Content.ReadAsStringAsync();
                    logger.LogWarning("Telegram rejected chatId {ChatId}: {Body}", chatId, body);
                }
                else
                {
                    logger.LogInformation("Sent to {ChatId}: {Message}", chatId, request.Message);
                }
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Failed sending to {ChatId}", chatId);
            }
        }
    }

    logger.LogInformation("WebSocket client disconnected");
});

app.Run();

record WsRequest(string ApiKey, string[] ChatIds, string Message);
