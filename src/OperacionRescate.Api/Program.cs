using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Infrastructure;
using OperacionRescate.Api.Errors;
using OperacionRescate.Api.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddControllers()
    .ConfigureApiBehaviorOptions(options =>
    {
        // Errores de binding (JSON malformado, tipos incorrectos, campos obligatorios):
        // 400 con problem+json, sin los mensajes internos del deserializador.
        options.InvalidModelStateResponseFactory = context =>
        {
            var jsonInvalido = context.ModelState.Keys.Any(k => k.StartsWith('$') || k == "request");
            var detail = jsonInvalido
                ? "El cuerpo de la solicitud no es un JSON válido o contiene valores con tipo incorrecto (la cantidad debe ser un entero)."
                : "La solicitud contiene campos obligatorios vacíos o inválidos.";

            var factory = context.HttpContext.RequestServices.GetRequiredService<ProblemDetailsFactory>();
            var problem = factory.CreateProblemDetails(context.HttpContext, StatusCodes.Status400BadRequest, "Solicitud inválida", detail: detail);

            return new ObjectResult(problem)
            {
                StatusCode = StatusCodes.Status400BadRequest,
                ContentTypes = { "application/problem+json" }
            };
        };
    });

// Todas las respuestas de error usan problem+json.
builder.Services.AddProblemDetails(options =>
{
    options.CustomizeProblemDetails = context =>
    {
        context.ProblemDetails.Extensions.Remove("traceId");
    };
});
builder.Services.AddExceptionHandler<GlobalExceptionHandler>();
builder.Services.Configure<ExceptionHandlerOptions>(options =>
{
    // El manejador global decide la respuesta; el framework registra la excepción.
    options.SuppressDiagnosticsCallback = _ => false;
});

builder.Services.AddSingleton<IInventarioService, InventarioService>();
builder.Services.AddSingleton<IPedidoService, PedidoService>();

var app = builder.Build();

app.UseExceptionHandler();
app.UseStatusCodePages();

app.MapControllers();

app.Run();

public partial class Program { }
