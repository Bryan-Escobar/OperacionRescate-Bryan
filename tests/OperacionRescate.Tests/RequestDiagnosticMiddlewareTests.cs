using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using OperacionRescate.Api.Errors;
using OperacionRescate.Api.Middleware;
using OperacionRescate.Tests.Soporte;
using Serilog.Events;

namespace OperacionRescate.Tests;

public class RequestDiagnosticMiddlewareTests
{
    private readonly CollectingSink _sink = new();

    private async Task<DefaultHttpContext> Ejecutar(RequestDelegate next, Action<DefaultHttpContext>? preparar = null, TimeProvider? reloj = null)
    {
        var middleware = new RequestDiagnosticMiddleware(
            next,
            LoggerDePrueba.Crear<RequestDiagnosticMiddleware>(_sink),
            reloj ?? new FakeTimeProvider(0, 1000));

        var context = new DefaultHttpContext();
        context.Request.Method = "GET";
        context.Request.Path = "/api/inventario/LAP-001";
        context.Response.Body = new MemoryStream();
        preparar?.Invoke(context);

        await middleware.InvokeAsync(context);
        return context;
    }

    // INC-005
    [Fact]
    public async Task CorrelationIdValido_SeConservaEnContextoYEnLogs()
    {
        const string cid = "8d2c5e2a-3a0e-4e3a-9d7a-0d0b3e3c9f11";

        var context = await Ejecutar(_ => Task.CompletedTask,
            c => c.Request.Headers[RequestDiagnosticMiddleware.CorrelationHeader] = cid);

        Assert.Equal(cid, context.GetCorrelationId());
        var fin = Assert.Single(_sink.DeFinalizacion());
        Assert.Equal(cid, CollectingSink.Prop(fin, "CorrelationId"));
    }

    // INC-005: identificadores hostiles se reemplazan por un GUID nuevo
    [Theory]
    [InlineData("")]
    [InlineData("abc-8d2c5e2a-3a0e-4e3a-9d7a-0d0b3e3c9f11-zzz")]
    [InlineData(" 8d2c5e2a-3a0e-4e3a-9d7a-0d0b3e3c9f1 ")]
    [InlineData("{8d2c5e2a-3a0e-4e3a-9d7a-0d0b3e3c9f11}")]
    [InlineData("8d2c5e2a3a0e4e3a9d7a0d0b3e3c9f11")]
    [InlineData("no es un guid; DROP TABLE")]
    public void CorrelationIdInvalido_SeGeneraUnoNuevo(string hostil)
    {
        var resultado = RequestDiagnosticMiddleware.ResolverCorrelationId(hostil);

        Assert.NotEqual(hostil, resultado);
        Assert.True(Guid.TryParseExact(resultado, "D", out _));
    }

    [Fact]
    public void CorrelationIdMuyLargoOMultiple_SeGeneraUnoNuevo()
    {
        var valido = Guid.NewGuid().ToString();

        Assert.NotEqual(new string('x', 300), RequestDiagnosticMiddleware.ResolverCorrelationId(new string('x', 300)));
        Assert.NotEqual(valido, RequestDiagnosticMiddleware.ResolverCorrelationId(new Microsoft.Extensions.Primitives.StringValues([valido, valido])));
    }

    [Theory]
    [InlineData("run-3f9a1c0b7d21", "run-3f9a1c0b7d21")]
    [InlineData(null, "sin-run")]
    [InlineData("", "sin-run")]
    [InlineData("run con espacios", "sin-run")]
    [InlineData("run;DROP", "sin-run")]
    public void LabRunId_SeValida(string? entrada, string esperado)
    {
        Assert.Equal(esperado, RequestDiagnosticMiddleware.ResolverLabRunId(entrada));
        Assert.Equal("sin-run", RequestDiagnosticMiddleware.ResolverLabRunId(new string('a', 65)));
    }

    // INC-008: con un reloj controlado la duración es exacta y determinista
    [Fact]
    public async Task ElapsedMs_SeMideConElRelojInyectado()
    {
        // 0 µs al inicio, 250 000 µs al final -> 250 ms
        await Ejecutar(_ => Task.CompletedTask, reloj: new FakeTimeProvider(0, 250_000));

        var fin = Assert.Single(_sink.DeFinalizacion());
        Assert.Equal(250.0, ((ScalarValue)fin.Properties["ElapsedMs"]).Value);
        Assert.Equal(LogEventLevel.Information, fin.Level);
        Assert.Equal("/api/inventario/LAP-001", CollectingSink.Prop(fin, "RequestPath"));
        Assert.Equal(200, ((ScalarValue)fin.Properties["StatusCode"]).Value);
    }

    [Fact]
    public async Task RequestPath_NoIncluyeQueryString()
    {
        await Ejecutar(_ => Task.CompletedTask, c => c.Request.QueryString = new QueryString("?token=secreto"));

        Assert.DoesNotContain(_sink.Eventos, e => e.RenderMessage().Contains("secreto")
            || e.Properties.Values.Any(v => v.ToString().Contains("secreto")));
    }

    // INC-004/INC-005: excepción manejada por el manejador global -> un único registro con Exception
    [Fact]
    public async Task ExcepcionManejada_SeRegistraUnaSolaVezYFinalizaConError()
    {
        var error = new InvalidOperationException("Fallo simulado");

        await Ejecutar(c =>
        {
            c.Features.Set<IExceptionHandlerFeature>(new ExceptionHandlerFeature { Error = error, Path = "/x" });
            c.Response.StatusCode = 500;
            return Task.CompletedTask;
        });

        var conExcepcion = Assert.Single(_sink.Eventos, e => e.Exception is not null);
        Assert.Same(error, conExcepcion.Exception);
        Assert.False(conExcepcion.Properties.ContainsKey("ElapsedMs"));
        var fin = Assert.Single(_sink.DeFinalizacion());
        Assert.Equal(LogEventLevel.Error, fin.Level);
        Assert.Equal(500, ((ScalarValue)fin.Properties["StatusCode"]).Value);
    }

    // R7: excepción que escapa al pipeline -> se registra una vez, 500 seguro, sin reejecutar
    [Fact]
    public async Task ExcepcionNoManejada_SeRegistraUnaVezYDevuelve500Seguro()
    {
        var llamadas = 0;

        var context = await Ejecutar(_ =>
        {
            llamadas++;
            throw new InvalidOperationException("Fallo simulado de laboratorio");
        });

        Assert.Equal(1, llamadas);
        Assert.Equal(500, context.Response.StatusCode);
        Assert.Single(_sink.Eventos, e => e.Exception is not null);
        Assert.Single(_sink.DeFinalizacion());

        context.Response.Body.Position = 0;
        var cuerpo = await new StreamReader(context.Response.Body).ReadToEndAsync();
        Assert.Contains(context.GetCorrelationId()!, cuerpo);
        Assert.DoesNotContain("Fallo simulado", cuerpo);
        Assert.DoesNotContain("Exception", cuerpo);
    }

    // Error de negocio (409) -> Warning, sin evento con Exception ni nivel Error
    [Fact]
    public async Task ErrorDeNegocio_NoSeClasificaComoExcepcionInterna()
    {
        await Ejecutar(c =>
        {
            c.Features.Set<IExceptionHandlerFeature>(new ExceptionHandlerFeature
            {
                Error = new StockInsuficienteException("No hay unidades suficientes de SSD-005."),
                Path = "/api/pedidos"
            });
            c.Response.StatusCode = 409;
            return Task.CompletedTask;
        });

        Assert.DoesNotContain(_sink.Eventos, e => e.Level >= LogEventLevel.Error || e.Exception is not null);
        Assert.Equal(LogEventLevel.Warning, Assert.Single(_sink.DeFinalizacion()).Level);
    }

    // R6: peticiones simultáneas no comparten CorrelationId ni LabRunId
    [Fact]
    public async Task PeticionesSimultaneas_NoMezclanContexto()
    {
        var logger = LoggerDePrueba.Crear<RequestDiagnosticMiddleware>(_sink);
        var barrera = new Barrier(2);

        async Task<string> Una(string cid, string run)
        {
            var middleware = new RequestDiagnosticMiddleware(async ctx =>
            {
                await Task.Yield();
                barrera.SignalAndWait(TimeSpan.FromSeconds(5)); // ambas peticiones dentro a la vez
                logger.LogInformation("trabajo interno");
            }, logger, new FakeTimeProvider(0, 10));

            var context = new DefaultHttpContext();
            context.Request.Headers[RequestDiagnosticMiddleware.CorrelationHeader] = cid;
            context.Request.Headers[RequestDiagnosticMiddleware.LabRunHeader] = run;
            await middleware.InvokeAsync(context);
            return cid;
        }

        var a = Guid.NewGuid().ToString();
        var b = Guid.NewGuid().ToString();
        await Task.WhenAll(Task.Run(() => Una(a, "run-a")), Task.Run(() => Una(b, "run-b")));

        Assert.Equal(4, _sink.Eventos.Count);
        Assert.All(_sink.Eventos, e =>
        {
            var cid = CollectingSink.Prop(e, "CorrelationId");
            var run = CollectingSink.Prop(e, "LabRunId");
            Assert.True((cid == a && run == "run-a") || (cid == b && run == "run-b"));
        });
    }
}
