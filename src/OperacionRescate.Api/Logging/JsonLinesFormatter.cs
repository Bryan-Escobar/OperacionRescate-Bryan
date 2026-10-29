using System.Globalization;
using Serilog.Events;
using Serilog.Formatting;
using Serilog.Formatting.Display;
using Serilog.Formatting.Json;

namespace OperacionRescate.Api.Logging;

/// <summary>
/// Formato JSON Lines: un objeto JSON por línea, con las propiedades del evento en
/// el nivel superior (no dentro de "Properties"), Timestamp en UTC terminado en Z y
/// la excepción completa (tipo, mensaje y traza) en "Exception".
/// </summary>
public sealed class JsonLinesFormatter : ITextFormatter
{
    private static readonly HashSet<string> Reservadas = new(StringComparer.Ordinal)
    {
        "Timestamp", "Level", "MessageTemplate", "Message", "Exception"
    };

    private readonly JsonValueFormatter _valueFormatter = new(typeTagName: null);

    // ":lj" renderiza los textos sin comillas y los objetos como JSON.
    private readonly MessageTemplateTextFormatter _messageFormatter = new("{Message:lj}", CultureInfo.InvariantCulture);

    public void Format(LogEvent logEvent, TextWriter output)
    {
        output.Write("{\"Timestamp\":\"");
        output.Write(logEvent.Timestamp.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture));
        output.Write("\",\"Level\":\"");
        output.Write(logEvent.Level);
        output.Write("\",\"MessageTemplate\":");
        JsonValueFormatter.WriteQuotedJsonString(logEvent.MessageTemplate.Text, output);
        output.Write(",\"Message\":");
        var mensaje = new StringWriter(CultureInfo.InvariantCulture);
        _messageFormatter.Format(logEvent, mensaje);
        JsonValueFormatter.WriteQuotedJsonString(mensaje.ToString(), output);

        if (logEvent.Exception is not null)
        {
            output.Write(",\"Exception\":");
            JsonValueFormatter.WriteQuotedJsonString(logEvent.Exception.ToString(), output);
        }

        foreach (var (nombre, valor) in logEvent.Properties)
        {
            if (Reservadas.Contains(nombre))
            {
                continue;
            }

            output.Write(',');
            JsonValueFormatter.WriteQuotedJsonString(nombre, output);
            output.Write(':');
            _valueFormatter.Format(valor, output);
        }

        output.Write('}');
        output.WriteLine();
    }
}
