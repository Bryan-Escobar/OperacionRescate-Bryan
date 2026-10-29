using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;

namespace OperacionRescate.Api.Errors;

/// <summary>
/// Punto único que convierte excepciones en respuestas application/problem+json.
/// Solo decide la respuesta: el registro de la excepción lo hace
/// RequestDiagnosticMiddleware, para que quede una sola vez en los logs.
/// </summary>
public sealed class GlobalExceptionHandler : IExceptionHandler
{
    private readonly IProblemDetailsService _problemDetails;

    public GlobalExceptionHandler(IProblemDetailsService problemDetails)
    {
        _problemDetails = problemDetails;
    }

    public async ValueTask<bool> TryHandleAsync(HttpContext httpContext, Exception exception, CancellationToken cancellationToken)
    {
        var problem = exception switch
        {
            AppException app => new ProblemDetails
            {
                Status = app.StatusCode,
                Title = app.Title,
                Detail = app.Message
            },
            BadHttpRequestException bad => new ProblemDetails
            {
                Status = bad.StatusCode,
                Title = "Solicitud inválida",
                Detail = "La solicitud HTTP no es válida."
            },
            // Error inesperado: mensaje genérico. El detalle real solo va a los logs.
            _ => new ProblemDetails
            {
                Status = StatusCodes.Status500InternalServerError,
                Title = "Error interno del servidor",
                Detail = "Ocurrió un error inesperado. Contacte a soporte indicando el correlationId."
            }
        };

        httpContext.Response.StatusCode = problem.Status!.Value;

        return await _problemDetails.TryWriteAsync(new ProblemDetailsContext
        {
            HttpContext = httpContext,
            ProblemDetails = problem
        });
    }
}
