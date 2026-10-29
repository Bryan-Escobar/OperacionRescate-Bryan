using System.Collections.Concurrent;
using Serilog;
using Serilog.Core;
using Serilog.Events;
using Microsoft.Extensions.Logging;
using Serilog.Extensions.Logging;

namespace OperacionRescate.Tests.Soporte;

/// <summary>Sink de Serilog que guarda los eventos en memoria para inspeccionarlos.</summary>
public sealed class CollectingSink : ILogEventSink
{
    private readonly ConcurrentQueue<LogEvent> _eventos = new();

    public IReadOnlyList<LogEvent> Eventos => _eventos.ToList();

    public void Emit(LogEvent logEvent) => _eventos.Enqueue(logEvent);

    public IReadOnlyList<LogEvent> DeFinalizacion() =>
        Eventos.Where(e => e.Properties.ContainsKey("ElapsedMs")).ToList();

    public static string? Prop(LogEvent e, string nombre) =>
        e.Properties.TryGetValue(nombre, out var v) && v is ScalarValue { Value: var x } ? x?.ToString() : null;
}

/// <summary>Reloj controlado: cada llamada a GetTimestamp avanza un paso fijo.</summary>
public sealed class FakeTimeProvider : TimeProvider
{
    private readonly Queue<long> _timestamps;

    public FakeTimeProvider(params long[] timestamps)
    {
        _timestamps = new Queue<long>(timestamps);
    }

    // 1 tick = 1 microsegundo, para que los milisegundos sean exactos.
    public override long TimestampFrequency => 1_000_000;

    public override long GetTimestamp() => _timestamps.Dequeue();
}

public static class LoggerDePrueba
{
    public static Microsoft.Extensions.Logging.ILogger<T> Crear<T>(CollectingSink sink)
    {
        var serilog = new LoggerConfiguration()
            .MinimumLevel.Verbose()
            .Enrich.FromLogContext()
            .WriteTo.Sink(sink)
            .CreateLogger();

        return new LoggerFactory([new SerilogLoggerProvider(serilog, dispose: true)]).CreateLogger<T>();
    }
}
