using Microsoft.Extensions.Logging.Abstractions;
using OperacionRescate.Api.Errors;
using OperacionRescate.Api.Models;
using OperacionRescate.Api.Services;

namespace OperacionRescate.Tests;

public class PedidoServiceTests
{
    private readonly InventarioService _inventario = new(NullLogger<InventarioService>.Instance);
    private readonly PedidoService _pedidos;

    public PedidoServiceTests()
    {
        // Instancias nuevas por prueba: no se comparte estado entre pruebas.
        _pedidos = new PedidoService(_inventario, NullLogger<PedidoService>.Instance);
    }

    private static CrearPedidoRequest Pedido(params (string Sku, int Cantidad)[] items) => new()
    {
        ClienteId = "CLI-001",
        Items = items.Select(i => new ItemPedidoRequest { Sku = i.Sku, Cantidad = i.Cantidad }).ToList()
    };

    private int Stock(string sku) => _inventario.ObtenerPorSku(sku).Stock;

    [Fact]
    public void CrearPedido_Valido_DescuentaStockYCalculaTotal()
    {
        var pedido = _pedidos.CrearPedido(Pedido(("LAP-001", 2), ("MOU-002", 3)));

        Assert.Equal("Confirmado", pedido.Estado);
        Assert.Equal(2 * 899.90m + 3 * 19.90m, pedido.Total);
        Assert.Equal(498, Stock("LAP-001"));
        Assert.Equal(997, Stock("MOU-002"));
        Assert.Same(pedido, _pedidos.ObtenerPorId(pedido.Id));
    }

    // INC-002
    [Theory]
    [InlineData(0)]
    [InlineData(-5)]
    public void CrearPedido_CantidadNoPositiva_Lanza400SinAlterarStock(int cantidad)
    {
        var ex = Assert.Throws<ValidacionException>(() => _pedidos.CrearPedido(Pedido(("LAP-001", cantidad))));

        Assert.Equal(400, ex.StatusCode);
        Assert.Equal(500, Stock("LAP-001"));
    }

    // INC-002: casos cercanos (cuerpos incompletos)
    [Fact]
    public void CrearPedido_SinItemsOSinCliente_Lanza400()
    {
        Assert.Throws<ValidacionException>(() => _pedidos.CrearPedido(Pedido()));
        Assert.Throws<ValidacionException>(() => _pedidos.CrearPedido(new CrearPedidoRequest { ClienteId = "CLI-001", Items = null! }));
        Assert.Throws<ValidacionException>(() => _pedidos.CrearPedido(new CrearPedidoRequest
        {
            ClienteId = " ",
            Items = [new ItemPedidoRequest { Sku = "LAP-001", Cantidad = 1 }]
        }));
    }

    // INC-001 dentro de un pedido
    [Fact]
    public void CrearPedido_SkuInexistente_Lanza404SinAlterarStock()
    {
        var ex = Assert.Throws<RecursoNoEncontradoException>(() =>
            _pedidos.CrearPedido(Pedido(("LAP-001", 1), ("NOEXISTE-000", 1))));

        Assert.Equal(404, ex.StatusCode);
        Assert.Equal(500, Stock("LAP-001"));
    }

    // INC-003
    [Fact]
    public void CrearPedido_StockInsuficiente_Lanza409YEsAtomico()
    {
        var ex = Assert.Throws<StockInsuficienteException>(() =>
            _pedidos.CrearPedido(Pedido(("LAP-001", 1), ("SSD-005", 9))));

        Assert.Equal(409, ex.StatusCode);
        Assert.Contains("SSD-005", ex.Message);
        Assert.Equal(500, Stock("LAP-001"));
        Assert.Equal(8, Stock("SSD-005"));
    }

    // INC-003: el mismo SKU repartido en varios ítems no puede superar el stock
    [Fact]
    public void CrearPedido_SkuRepetidoQueSuperaStock_Lanza409()
    {
        Assert.Throws<StockInsuficienteException>(() =>
            _pedidos.CrearPedido(Pedido(("SSD-005", 5), ("ssd-005", 4))));

        Assert.Equal(8, Stock("SSD-005"));
    }

    [Fact]
    public void CrearPedido_ExactamenteElStockDisponible_SeAcepta()
    {
        _pedidos.CrearPedido(Pedido(("SSD-005", 8)));

        Assert.Equal(0, Stock("SSD-005"));
    }

    [Fact]
    public void ObtenerPorId_Inexistente_Lanza404()
    {
        var ex = Assert.Throws<RecursoNoEncontradoException>(() => _pedidos.ObtenerPorId("no-existe"));

        Assert.Equal(404, ex.StatusCode);
    }
}
