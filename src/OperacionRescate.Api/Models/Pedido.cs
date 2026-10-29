namespace OperacionRescate.Api.Models;

public class Pedido
{
    public string Id { get; set; } = string.Empty;

    public string ClienteId { get; set; } = string.Empty;

    public string Estado { get; set; } = "Confirmado";

    public decimal Total { get; set; }

    public List<ItemPedido> Items { get; set; } = new();
}
