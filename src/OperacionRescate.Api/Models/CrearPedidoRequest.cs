namespace OperacionRescate.Api.Models;

public class CrearPedidoRequest
{
    public string ClienteId { get; set; } = string.Empty;

    public List<ItemPedidoRequest> Items { get; set; } = new();
}
