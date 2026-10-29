using OperacionRescate.Api.Models;

namespace OperacionRescate.Api.Services;

public interface IInventarioService
{
    IReadOnlyCollection<Producto> ObtenerTodos();

    Producto ObtenerPorSku(string sku);

    Producto? ObtenerProductoParaPedido(string sku);
}
