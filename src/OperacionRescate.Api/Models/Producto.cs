namespace OperacionRescate.Api.Models;

public class Producto
{
    public string Sku { get; set; } = string.Empty;

    public string Nombre { get; set; } = string.Empty;

    public int Stock { get; set; }

    public decimal Precio { get; set; }
}
