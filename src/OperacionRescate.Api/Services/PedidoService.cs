using System.Collections.Concurrent;
using OperacionRescate.Api.Errors;
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
        // 1) Validación de la solicitud: no toca el inventario.
        Validar(request);

        var items = request.Items;
        _logger.LogInformation("Procesando pedido de {ClienteId} con primer SKU {PrimerSku}", request.ClienteId, items[0].Sku);

        lock (_sync)
        {
            // 2) Todos los SKU deben existir (404) antes de seguir.
            var productos = new Dictionary<string, Producto>(StringComparer.OrdinalIgnoreCase);
            foreach (var item in items)
            {
                var producto = _inventario.ObtenerProductoParaPedido(item.Sku)
                    ?? throw new RecursoNoEncontradoException($"No existe un producto con SKU '{item.Sku}'.");
                productos[item.Sku] = producto;
            }

            // 3) Stock suficiente para todo el pedido (409). Se agrupa por SKU para
            //    que un mismo producto repetido en varios ítems no supere el stock.
            foreach (var grupo in items.GroupBy(i => i.Sku, StringComparer.OrdinalIgnoreCase))
            {
                var producto = productos[grupo.Key];
                var solicitado = grupo.Sum(i => i.Cantidad);
                if (solicitado > producto.Stock)
                {
                    throw new StockInsuficienteException(
                        $"No hay unidades suficientes de {producto.Sku}. Solicitadas: {solicitado}, disponibles: {producto.Stock}.");
                }
            }

            // 4) Solo aquí, con todo validado, se descuenta el stock: el pedido es atómico.
            var total = 0m;
            var cantidadTotal = 0;
            foreach (var item in items)
            {
                var producto = productos[item.Sku];
                producto.Stock -= item.Cantidad;
                total += producto.Precio * item.Cantidad;
                cantidadTotal += item.Cantidad;
            }

            var precioPromedio = total / cantidadTotal;
            _logger.LogInformation("Precio promedio por unidad del pedido de {ClienteId}: {PrecioPromedio}", request.ClienteId, precioPromedio);

            var pedido = new Pedido
            {
                Id = Guid.NewGuid().ToString(),
                ClienteId = request.ClienteId,
                Estado = "Confirmado",
                Total = total,
                Items = items.Select(item => new ItemPedido
                {
                    Sku = productos[item.Sku].Sku,
                    Cantidad = item.Cantidad,
                    PrecioUnitario = productos[item.Sku].Precio
                }).ToList()
            };

            _pedidos[pedido.Id] = pedido;

            _logger.LogInformation("Pedido {PedidoId} procesado correctamente", pedido.Id);

            return pedido;
        }
    }

    public Pedido ObtenerPorId(string id)
    {
        return _pedidos.TryGetValue(id, out var pedido)
            ? pedido
            : throw new RecursoNoEncontradoException($"No existe un pedido con id '{id}'.");
    }

    private static void Validar(CrearPedidoRequest? request)
    {
        if (request is null)
        {
            throw new ValidacionException("El cuerpo del pedido es obligatorio.");
        }

        if (string.IsNullOrWhiteSpace(request.ClienteId))
        {
            throw new ValidacionException("El campo 'clienteId' es obligatorio.");
        }

        if (request.Items is null || request.Items.Count == 0)
        {
            throw new ValidacionException("El pedido debe contener al menos un ítem.");
        }

        foreach (var item in request.Items)
        {
            if (item is null || string.IsNullOrWhiteSpace(item.Sku))
            {
                throw new ValidacionException("Cada ítem debe indicar un 'sku'.");
            }

            if (item.Cantidad <= 0)
            {
                throw new ValidacionException($"La cantidad del SKU '{item.Sku}' debe ser un entero mayor que cero.");
            }
        }
    }
}
