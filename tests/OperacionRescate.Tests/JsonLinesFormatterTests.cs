using System.Text.Json;
using OperacionRescate.Api.Logging;
using Serilog.Events;
using Serilog.Parsing;

namespace OperacionRescate.Tests;

// INC-007
public class JsonLinesFormatterTests
{
    private static JsonElement Formatear(LogEvent evento, out string linea)
    {
        var writer = new StringWriter();
        new JsonLinesFormatter().Format(evento, writer);
        linea = writer.ToString();
        return JsonDocument.Parse(linea).RootElement;
    }

    private static LogEvent Evento(LogEventLevel nivel, Exception? ex = null)
    {
        var template = new MessageTemplateParser().Parse("HTTP {RequestMethod} {RequestPath} finalizó con {StatusCode}");
        return new LogEvent(
            new DateTimeOffset(2026, 10, 28, 11, 10, 0, 123, TimeSpan.FromHours(-6)),
            nivel, ex, template,
            [
                new LogEventProperty("RequestMethod", new ScalarValue("GET")),
                new LogEventProperty("RequestPath", new ScalarValue("/api/inventario/LAP-001")),
                new LogEventProperty("StatusCode", new ScalarValue(200)),
                new LogEventProperty("ElapsedMs", new ScalarValue(18.4)),
                new LogEventProperty("CorrelationId", new ScalarValue("8d2c5e2a-3a0e-4e3a-9d7a-0d0b3e3c9f11"))
            ]);
    }

    [Fact]
    public void Formato_UnaLineaConPropiedadesEnNivelSuperiorYTiposCorrectos()
    {
        var json = Formatear(Evento(LogEventLevel.Information), out var linea);

        Assert.Single(linea.Split('\n', StringSplitOptions.RemoveEmptyEntries));
        Assert.Equal("2026-10-28T17:10:00.123Z", json.GetProperty("Timestamp").GetString()); // convertido a UTC
        Assert.Equal("Information", json.GetProperty("Level").GetString());
        Assert.Equal("HTTP {RequestMethod} {RequestPath} finalizó con {StatusCode}", json.GetProperty("MessageTemplate").GetString());
        Assert.Equal("HTTP GET /api/inventario/LAP-001 finalizó con 200", json.GetProperty("Message").GetString());
        Assert.Equal(JsonValueKind.Number, json.GetProperty("StatusCode").ValueKind);
        Assert.Equal(18.4, json.GetProperty("ElapsedMs").GetDouble());
        Assert.Equal("/api/inventario/LAP-001", json.GetProperty("RequestPath").GetString());
        Assert.False(json.TryGetProperty("Properties", out _));
    }

    [Fact]
    public void Excepcion_SeEscribeCompletaEnUnaSolaLinea()
    {
        Exception capturada;
        try { throw new InvalidOperationException("Fallo simulado\ncon salto de línea"); }
        catch (Exception ex) { capturada = ex; }

        var json = Formatear(Evento(LogEventLevel.Error, capturada), out var linea);

        Assert.Single(linea.Split('\n', StringSplitOptions.RemoveEmptyEntries));
        var texto = json.GetProperty("Exception").GetString()!;
        Assert.Contains("System.InvalidOperationException: Fallo simulado", texto);
        Assert.Contains(" at ", texto); // la traza se conserva
        Assert.Equal("Error", json.GetProperty("Level").GetString());
    }
}
