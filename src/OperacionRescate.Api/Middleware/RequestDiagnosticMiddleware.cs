using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;
using Serilog.Context;

namespace OperacionRescate.Api.Middleware;

/// <summary>
/// Primer componente del pipeline (envuelve al manejador global de excepciones).
/// Por cada petición: resuelve el CorrelationId y el LabRunId, los propaga a todos
/// los eventos de log mediante LogContext, mide la duración real y escribe
/// exactamente un evento de finalización con el código de estado final.
/// </summary>
public partial class RequestDiagnosticMiddleware
{
    public const string CorrelationHeader = "X-Correlation-ID";
    public const string LabRunHeader = "X-Lab-Run-Id";
    public const string SinRun = "sin-run";

    private const string CompletionTemplate = "HTTP {RequestMethod} {RequestPath} finalizó con {StatusCode} en {ElapsedMs} ms";
    private const string ExceptionTemplate = "Excepción no controlada en {RequestMethod} {RequestPath}";

    private readonly RequestDelegate _next;
    private readonly ILogger<RequestDiagnosticMiddleware> _logger;
    private readonly TimeProvider _time;

    public RequestDiagnosticMiddleware(RequestDelegate next, ILogger<RequestDiagnosticMiddleware> logger, TimeProvider time)
    {
        _next = next;
        _logger = logger;
        _time = time;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        var inicio = _time.GetTimestamp();

        var correlationId = ResolverCorrelationId(context.Request.Headers[CorrelationHeader]);
        var labRunId = ResolverLabRunId(context.Request.Headers[LabRunHeader]);
        context.SetCorrelationId(correlationId);

        // Se capturan al inicio: solo la ruta (sin query string) y el método original.
        var method = context.Request.Method;
        var path = (context.Request.PathBase + context.Request.Path).ToString();

        // Las cabeceras solo se pueden modificar antes de que empiece la respuesta.
        // OnStarting se ejecuta justo antes de enviarlas, incluso después de que el
        // manejador de excepciones haga Response.Clear(), así que la cabecera llega
        // también en las respuestas de error.
        context.Response.OnStarting(() =>
        {
            context.Response.Headers[CorrelationHeader] = correlationId;
            return Task.CompletedTask;
        });

        // LogContext usa AsyncLocal: las propiedades viven solo en el flujo de esta
        // petición, así que dos peticiones simultáneas no se mezclan.
        using (LogContext.PushProperty("CorrelationId", correlationId))
        using (LogContext.PushProperty("LabRunId", labRunId))
        {
            var statusCode = StatusCodes.Status500InternalServerError;
            var huboExcepcion = false;
            try
            {
                await _next(context);
                statusCode = context.Response.StatusCode;

                // El manejador global ya generó la respuesta; si fue un error inesperado
                // (5xx) se registra aquí, una sola vez, con todo el detalle.
                var handled = context.Features.Get<IExceptionHandlerFeature>()?.Error;
                if (handled is not null && statusCode >= StatusCodes.Status500InternalServerError)
                {
                    huboExcepcion = true;
                    _logger.LogError(handled, ExceptionTemplate, method, path);
                }
            }
            catch (Exception ex)
            {
                // Excepción que el manejador global no pudo resolver (por ejemplo, la
                // respuesta ya había comenzado). Se registra una vez y no se vuelve a
                // ejecutar el pipeline.
                huboExcepcion = true;
                _logger.LogError(ex, ExceptionTemplate, method, path);

                if (!context.Response.HasStarted)
                {
                    statusCode = StatusCodes.Status500InternalServerError;
                    await EscribirErrorGenericoAsync(context, correlationId);
                }
                else
                {
                    // Ya se enviaron cabeceras/cuerpo: no se puede reemplazar la
                    // respuesta. Se corta la conexión para que el cliente no tome una
                    // respuesta truncada como válida.
                    statusCode = context.Response.StatusCode;
                    context.Abort();
                }
            }
            finally
            {
                var elapsedMs = _time.GetElapsedTime(inicio).TotalMilliseconds;
                var level = NivelPara(statusCode, huboExcepcion);
                _logger.Log(level, CompletionTemplate, method, path, statusCode, elapsedMs);
            }
        }
    }

    public static LogLevel NivelPara(int statusCode, bool huboExcepcion)
    {
        if (huboExcepcion || statusCode >= StatusCodes.Status500InternalServerError)
        {
            return LogLevel.Error;
        }

        return statusCode >= StatusCodes.Status400BadRequest ? LogLevel.Warning : LogLevel.Information;
    }

    public static string ResolverCorrelationId(Microsoft.Extensions.Primitives.StringValues valores)
    {
        // Solo se acepta un único valor con formato GUID 8-4-4-4-12 exacto (36 caracteres).
        // La comprobación de longitud descarta espacios y textos que *contienen* un GUID.
        if (valores.Count == 1
            && valores[0] is { Length: 36 } candidato
            && Guid.TryParseExact(candidato, "D", out var guid))
        {
            return guid.ToString("D");
        }

        return Guid.NewGuid().ToString("D");
    }

    public static string ResolverLabRunId(Microsoft.Extensions.Primitives.StringValues valores)
    {
        return valores.Count == 1 && valores[0] is { } valor && LabRunIdRegex().IsMatch(valor)
            ? valor
            : SinRun;
    }

    private static async Task EscribirErrorGenericoAsync(HttpContext context, string correlationId)
    {
        context.Response.Clear();
        context.Response.StatusCode = StatusCodes.Status500InternalServerError;
        var problem = new ProblemDetails
        {
            Type = "https://tools.ietf.org/html/rfc9110#section-15.6.1",
            Title = "Error interno del servidor",
            Status = StatusCodes.Status500InternalServerError,
            Detail = "Ocurrió un error inesperado. Contacte a soporte indicando el correlationId."
        };
        problem.Extensions["correlationId"] = correlationId;
        await context.Response.WriteAsJsonAsync(problem, (System.Text.Json.JsonSerializerOptions?)null, "application/problem+json");
    }

    [GeneratedRegex("^[A-Za-z0-9._-]{1,64}$")]
    private static partial Regex LabRunIdRegex();
}
