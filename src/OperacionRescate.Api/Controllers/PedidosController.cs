using Microsoft.AspNetCore.Mvc;
using OperacionRescate.Api.Models;
using OperacionRescate.Api.Services;

namespace OperacionRescate.Api.Controllers;

[Route("api/[controller]")]
public class PedidosController : ControllerBase
{
    private readonly IPedidoService _pedidos;

    public PedidosController(IPedidoService pedidos)
    {
        _pedidos = pedidos;
    }

    [HttpPost]
    public IActionResult Crear([FromBody] CrearPedidoRequest request)
    {
        var pedido = _pedidos.CrearPedido(request);
        return CreatedAtAction(nameof(Obtener), new { id = pedido.Id }, pedido);
    }

    [HttpGet("{id}")]
    public IActionResult Obtener(string id)
    {
        var pedido = _pedidos.ObtenerPorId(id);
        return Ok(pedido);
    }
}
