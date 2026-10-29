namespace OperacionRescate.Api.Middleware;

public class LegacyErrorMiddleware
{
    private readonly RequestDelegate _next;
    private readonly ILogger<LegacyErrorMiddleware> _logger;

    public LegacyErrorMiddleware(RequestDelegate next, ILogger<LegacyErrorMiddleware> logger)
    {
        _next = next;
        _logger = logger;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        try
        {
            await _next(context);
        }
        catch (Exception ex)
        {
            _logger.LogError("Error: " + ex.Message);

            context.Response.Clear();
            context.Response.StatusCode = StatusCodes.Status500InternalServerError;
            context.Response.ContentType = "text/plain";

            await context.Response.WriteAsync(ex.ToString());
        }
    }
}
