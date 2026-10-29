namespace OperacionRescate.Api.Errors;

/// <summary>
/// Error esperado de la aplicación (validación, no encontrado, conflicto).
/// Lo lanza la capa de negocio, que es quien sabe qué salió mal; el manejador
/// global lo traduce al código HTTP indicado. No es un error interno: no se
/// registra como Error.
/// </summary>
public abstract class AppException : Exception
{
    protected AppException(int statusCode, string title, string detail)
        : base(detail)
    {
        StatusCode = statusCode;
        Title = title;
    }

    public int StatusCode { get; }

    public string Title { get; }
}

public sealed class ValidacionException : AppException
{
    public ValidacionException(string detail)
        : base(StatusCodes.Status400BadRequest, "Solicitud inválida", detail)
    {
    }
}

public sealed class RecursoNoEncontradoException : AppException
{
    public RecursoNoEncontradoException(string detail)
        : base(StatusCodes.Status404NotFound, "Recurso no encontrado", detail)
    {
    }
}

public sealed class StockInsuficienteException : AppException
{
    public StockInsuficienteException(string detail)
        : base(StatusCodes.Status409Conflict, "Stock insuficiente", detail)
    {
    }
}
