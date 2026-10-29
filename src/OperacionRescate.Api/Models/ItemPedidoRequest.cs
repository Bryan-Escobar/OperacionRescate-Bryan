namespace OperacionRescate.Api.Models;

public class ItemPedidoRequest
{
    public string Sku { get; set; } = string.Empty;

    public int Cantidad { get; set; }
}
