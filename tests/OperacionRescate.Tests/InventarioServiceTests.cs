using Microsoft.Extensions.Logging.Abstractions;
using OperacionRescate.Api.Services;

namespace OperacionRescate.Tests;

public class InventarioServiceTests
{
    private static InventarioService CrearServicio()
    {
        return new InventarioService(NullLogger<InventarioService>.Instance);
    }

    [Fact]
    public void ObtenerTodos_DevuelveLosProductosSemilla()
    {
        var servicio = CrearServicio();

        var productos = servicio.ObtenerTodos();

        Assert.Equal(5, productos.Count);
        Assert.Contains(productos, p => p.Sku == "LAP-001" && p.Stock == 500);
        Assert.Contains(productos, p => p.Sku == "SSD-005" && p.Precio == 109.00m);
    }

    [Fact]
    public void ObtenerPorSku_DevuelveElProductoExistente()
    {
        var servicio = CrearServicio();

        var producto = servicio.ObtenerPorSku("LAP-001");

        Assert.Equal("Laptop Pro 14", producto.Nombre);
        Assert.Equal(899.90m, producto.Precio);
    }

    [Fact]
    public void ObtenerPorSku_IgnoraMayusculasYMinusculas()
    {
        var servicio = CrearServicio();

        var producto = servicio.ObtenerPorSku("lap-001");

        Assert.Equal("LAP-001", producto.Sku);
    }
}
