using Microsoft.AspNetCore.Mvc;
using OperacionRescate.Api.Services;

namespace OperacionRescate.Api.Controllers;

[Route("api/[controller]")]
public class InventarioController : ControllerBase
{
    private readonly IInventarioService _inventario;

    public InventarioController(IInventarioService inventario)
    {
        _inventario = inventario;
    }

    [HttpGet]
    public IActionResult Listar()
    {
        return Ok(_inventario.ObtenerTodos());
    }

    [HttpGet("{sku}")]
    public IActionResult Obtener(string sku)
    {
        return Ok(_inventario.ObtenerPorSku(sku));
    }
}
