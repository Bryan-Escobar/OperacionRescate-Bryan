using System.Collections.Concurrent;
using OperacionRescate.Api.Models;

namespace OperacionRescate.Api.Services;

public class PedidoService : IPedidoService
{
    private readonly ConcurrentDictionary<string, Pedido> _pedidos = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _sync = new();
    private readonly IInventarioService _inventario;
    private readonly ILogger<PedidoService> _logger;

    public PedidoService(IInventarioService inventario, ILogger<PedidoService> logger)
    {
        _inventario = inventario;
        _logger = logger;
    }

    public Pedido CrearPedido(CrearPedidoRequest request)
    {
        lock (_sync)
        {
            var items = request.Items;
            var primerSku = items.First().Sku;
            _logger.LogInformation($"Procesando pedido de {request.ClienteId} con primer SKU {primerSku}");

            var total = 0m;
            var cantidadTotal = 0;

            foreach (var item in items)
            {
                var producto = _inventario.ObtenerProductoParaPedido(item.Sku)!;
                total += producto.Precio * item.Cantidad;
                cantidadTotal += item.Cantidad;
            }

            var precioPromedio = total / cantidadTotal;
            _logger.LogInformation($"Precio promedio por unidad del pedido de {request.ClienteId}: {precioPromedio}");

            foreach (var item in items)
            {
                var producto = _inventario.ObtenerProductoParaPedido(item.Sku)!;
                producto.Stock -= item.Cantidad;
            }

            foreach (var item in items)
            {
                var producto = _inventario.ObtenerProductoParaPedido(item.Sku)!;
                if (producto.Stock < 0)
                {
                    throw new Exception("Error al procesar el pedido");
                }
            }

            var pedido = new Pedido
            {
                Id = Guid.NewGuid().ToString(),
                ClienteId = request.ClienteId,
                Estado = "Confirmado",
                Total = total,
                Items = items.Select(item =>
                {
                    var producto = _inventario.ObtenerProductoParaPedido(item.Sku)!;
                    return new ItemPedido
                    {
                        Sku = item.Sku,
                        Cantidad = item.Cantidad,
                        PrecioUnitario = producto.Precio
                    };
                }).ToList()
            };

            _pedidos[pedido.Id] = pedido;

            _logger.LogInformation($"Pedido {pedido.Id} procesado correctamente");

            return pedido;
        }
    }

    public Pedido? ObtenerPorId(string id)
    {
        _pedidos.TryGetValue(id, out var pedido);
        return pedido;
    }
}
