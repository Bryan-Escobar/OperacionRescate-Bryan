using OperacionRescate.Api.Models;

namespace OperacionRescate.Api.Services;

public interface IPedidoService
{
    Pedido CrearPedido(CrearPedidoRequest request);

    Pedido? ObtenerPorId(string id);
}
