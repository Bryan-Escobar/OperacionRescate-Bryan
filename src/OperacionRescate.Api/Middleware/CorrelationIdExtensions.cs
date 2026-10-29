namespace OperacionRescate.Api.Middleware;

public static class CorrelationIdExtensions
{
    private const string ItemKey = "OperacionRescate.CorrelationId";

    public static void SetCorrelationId(this HttpContext context, string correlationId)
    {
        context.Items[ItemKey] = correlationId;
    }

    public static string? GetCorrelationId(this HttpContext context)
    {
        return context.Items.TryGetValue(ItemKey, out var value) ? value as string : null;
    }
}
