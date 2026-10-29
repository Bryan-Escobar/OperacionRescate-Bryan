namespace OperacionRescate.Api.Models;

public class ItemPedido
{
    public string Sku { get; set; } = string.Empty;

    public int Cantidad { get; set; }

    public decimal PrecioUnitario { get; set; }
}
