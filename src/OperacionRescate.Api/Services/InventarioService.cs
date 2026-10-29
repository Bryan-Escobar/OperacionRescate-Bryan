using System.Collections.Concurrent;
using OperacionRescate.Api.Models;

namespace OperacionRescate.Api.Services;

public class InventarioService : IInventarioService
{
    private readonly ConcurrentDictionary<string, Producto> _productos;

    public InventarioService(ILogger<InventarioService> logger)
    {
        _productos = new ConcurrentDictionary<string, Producto>(StringComparer.OrdinalIgnoreCase);

        Agregar(new Producto { Sku = "LAP-001", Nombre = "Laptop Pro 14", Stock = 500, Precio = 899.90m });
        Agregar(new Producto { Sku = "MOU-002", Nombre = "Mouse inalámbrico", Stock = 1000, Precio = 19.90m });
        Agregar(new Producto { Sku = "TEC-003", Nombre = "Teclado mecánico", Stock = 300, Precio = 59.00m });
        Agregar(new Producto { Sku = "MON-004", Nombre = "Monitor 27 pulgadas", Stock = 150, Precio = 249.50m });
        Agregar(new Producto { Sku = "SSD-005", Nombre = "Disco SSD 1 TB", Stock = 8, Precio = 109.00m });

        logger.LogInformation($"Inventario inicializado con {_productos.Count} productos");
    }

    public IReadOnlyCollection<Producto> ObtenerTodos()
    {
        return _productos.Values.OrderBy(p => p.Sku, StringComparer.OrdinalIgnoreCase).ToList();
    }

    public Producto ObtenerPorSku(string sku)
    {
        return _productos[sku];
    }

    public Producto? ObtenerProductoParaPedido(string sku)
    {
        _productos.TryGetValue(sku, out var producto);
        return producto;
    }

    private void Agregar(Producto producto)
    {
        _productos[producto.Sku] = producto;
    }
}
