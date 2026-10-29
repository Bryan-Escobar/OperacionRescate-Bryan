using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;

namespace OperacionRescate.Tests;

/// <summary>
/// Pruebas de extremo a extremo sobre el pipeline real (TestServer). Cada clase usa
/// su propia API y una carpeta de logs temporal, independiente de corridas previas.
/// </summary>
public class ApiIntegrationTests : IDisposable
{
    private readonly string _logDir = Path.Combine(Path.GetTempPath(), "rescate-tests-" + Guid.NewGuid().ToString("N"));
    private readonly WebApplicationFactory<Program> _factory;
    private readonly HttpClient _client;

    public ApiIntegrationTests()
    {
        _factory = new WebApplicationFactory<Program>().WithWebHostBuilder(builder =>
            builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Serilog:WriteTo:1:Args:path"] = Path.Combine(_logDir, "api-.json"),
                ["Serilog:WriteTo:1:Args:shared"] = "false"
            })));
        _client = _factory.CreateClient();
    }

    public void Dispose()
    {
        _client.Dispose();
        _factory.Dispose();
        try { Directory.Delete(_logDir, recursive: true); } catch (IOException) { }
    }

    private static async Task<(JsonElement Json, string Cuerpo)> LeerProblema(HttpResponseMessage r)
    {
        Assert.Equal("application/problem+json", r.Content.Headers.ContentType?.MediaType);
        var cuerpo = await r.Content.ReadAsStringAsync();
        return (JsonDocument.Parse(cuerpo).RootElement, cuerpo);
    }

    private static string Cid(HttpResponseMessage r) => Assert.Single(r.Headers.GetValues("X-Correlation-ID"));

    // INC-004
    [Fact]
    public async Task ExcepcionDeLaboratorio_Devuelve500SeguroConCorrelationId()
    {
        var r = await _client.GetAsync("/api/lab/excepcion");

        Assert.Equal(HttpStatusCode.InternalServerError, r.StatusCode);
        var (json, cuerpo) = await LeerProblema(r);
        Assert.Equal(500, json.GetProperty("status").GetInt32());
        Assert.Equal(Cid(r), json.GetProperty("correlationId").GetString());
        foreach (var prohibido in new[] { "Fallo simulado", "Exception", "System.", " at ", ".cs", "OperacionRescate" })
        {
            Assert.DoesNotContain(prohibido, cuerpo);
        }
    }

    // INC-001
    [Fact]
    public async Task ProductoInexistente_Devuelve404ProblemJson()
    {
        const string cid = "8d2c5e2a-3a0e-4e3a-9d7a-0d0b3e3c9f11";
        var req = new HttpRequestMessage(HttpMethod.Get, "/api/inventario/NOEXISTE-999");
        req.Headers.Add("X-Correlation-ID", cid);

        var r = await _client.SendAsync(req);

        Assert.Equal(HttpStatusCode.NotFound, r.StatusCode);
        Assert.Equal(cid, Cid(r));
        var (json, _) = await LeerProblema(r);
        Assert.Equal(cid, json.GetProperty("correlationId").GetString());
    }

    // INC-002: JSON malformado y cantidad no entera -> 400 sin detalles del deserializador
    [Theory]
    [InlineData("{\"clienteId\":\"CLI-001\",\"items\":[")]
    [InlineData("{\"clienteId\":\"CLI-001\",\"items\":[{\"sku\":\"LAP-001\",\"cantidad\":1.5}]}")]
    [InlineData("{\"clienteId\":\"CLI-001\",\"items\":[{\"sku\":\"LAP-001\",\"cantidad\":0}]}")]
    public async Task PedidoInvalido_Devuelve400ProblemJson(string cuerpoPedido)
    {
        var r = await _client.PostAsync("/api/pedidos", new StringContent(cuerpoPedido, Encoding.UTF8, "application/json"));

        Assert.Equal(HttpStatusCode.BadRequest, r.StatusCode);
        var (json, cuerpo) = await LeerProblema(r);
        Assert.Equal(400, json.GetProperty("status").GetInt32());
        Assert.DoesNotContain("System.", cuerpo);
    }

    // INC-006: los eventos se almacenan en archivo, en JSON Lines, con la correlación de la petición
    [Fact]
    public async Task Logs_SeEscribenEnArchivoJsonLinesConLaCorrelacion()
    {
        var req = new HttpRequestMessage(HttpMethod.Get, "/api/inventario/LAP-001");
        req.Headers.Add("X-Lab-Run-Id", "run-prueba");
        var r = await _client.SendAsync(req);
        var cid = Cid(r);

        _factory.Dispose(); // cierra el logger y vacía el sink de archivo

        var lineas = Directory.GetFiles(_logDir).SelectMany(File.ReadAllLines).Where(l => l.Length > 0).ToList();
        var eventos = lineas.Select(l => JsonDocument.Parse(l).RootElement).ToList();
        var fin = Assert.Single(eventos, e =>
            e.TryGetProperty("CorrelationId", out var c) && c.GetString() == cid && e.TryGetProperty("ElapsedMs", out _));
        Assert.Equal(200, fin.GetProperty("StatusCode").GetInt32());
        Assert.Equal("run-prueba", fin.GetProperty("LabRunId").GetString());
        Assert.Equal("GET", fin.GetProperty("RequestMethod").GetString());
    }
}
