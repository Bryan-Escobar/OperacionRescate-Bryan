using Microsoft.AspNetCore.Mvc;

namespace OperacionRescate.Api.Controllers;

[Route("api/[controller]")]
public class LabController : ControllerBase
{
    [HttpGet("excepcion")]
    public IActionResult Excepcion()
    {
        throw new InvalidOperationException("Fallo simulado de laboratorio");
    }

    [HttpGet("lento")]
    public async Task<IActionResult> Lento([FromQuery] int? ms)
    {
        var esperado = Math.Clamp(ms ?? 0, 0, 2000);
        await Task.Delay(esperado);
        return Ok(new { esperadoMs = esperado });
    }
}
