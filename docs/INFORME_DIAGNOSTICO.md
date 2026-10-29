# Informe de diagnóstico — Operación Rescate

> Borrador de la Fase 1, escrito **antes** de corregir. La evidencia está en `evidencias/antes/`: `INC-00X.txt` contiene cada petición y su respuesta completa, `consola.txt` la salida de consola, `validador-antes.txt` la salida del validador (**11/100**) y `peticiones/` los cuerpos JSON enviados.

## Diagnóstico por incidente (estado recibido)

| Incidente | Cómo lo reproduje | Causa raíz (archivo/línea) |
|---|---|---|
| INC-001 | `GET /api/inventario/NOEXISTE-999` devuelve **500** `text/plain` con `KeyNotFoundException`. `GET /api/pedidos/no-existe` devuelve **204** vacío. | `Services/InventarioService.cs:30`: `_productos[sku]` lanza `KeyNotFoundException` cuando la clave no existe. `Controllers/PedidosController.cs:28`: `Ok(pedido)` con `null` produce 204 en lugar de 404. |
| INC-002 | `cantidad: 0` da **500** (`DivideByZeroException`). `cantidad: -5` da **201** con total negativo y **sube el stock** (500 → 505). `items: []` da 500 (`Sequence contains no elements`). JSON malformado y SKU inexistente dan 500 (`NullReferenceException`). | `Services/PedidoService.cs`: no hay ninguna validación. En la línea 37 (`total / cantidadTotal`) se divide entre 0. En la línea 43 (`Stock -= Cantidad`) una cantidad negativa suma. La línea 24 (`items.First()`) falla con la lista vacía. En las líneas 32 y 42, el operador `!` sobre `ObtenerProductoParaPedido` oculta el `null` de un SKU inexistente. Los controladores no tienen `[ApiController]`, así que un cuerpo inválido llega como `request == null`. |
| INC-003 | Con `SSD-005` (stock 8), un pedido de 9 da **500** "Error al procesar el pedido" y el stock queda en **-1**. Un pedido `[LAP-001 x1, SSD-005 x9]` falla y **descuenta igual** LAP-001 (505 → 504). | `Services/PedidoService.cs:40-53`: **primero descuenta** el stock y **después** revisa `Stock < 0` para lanzar un `Exception` genérico, sin revertir nada. El pedido no es atómico y el error no indica qué ítem ni por qué. |
| INC-004 | `GET /api/lab/excepcion` devuelve 500 `text/plain` con `System.InvalidOperationException`, la traza completa y la ruta `C:\Users\...\LabController.cs:line 11`. | `Middleware/LegacyErrorMiddleware.cs:26-28`: escribe `ex.ToString()` en la respuesta. Expone tipo, traza, espacios de nombres y rutas del servidor. |
| INC-005 | Ninguna respuesta trae `X-Correlation-ID`. Si se envía uno, se ignora. Los errores de consola no tienen identificador. | No existe ningún mecanismo de correlación (`Program.cs`). |
| INC-006 | Los logs solo aparecen en consola. No se crea la carpeta `logs/`, y el validador falla L01 a L09. | `Program.cs` usa el logging por defecto (provider de consola). No hay Serilog ni sink de archivo. |
| INC-007 | En consola aparece `fail: ... Error: The given key ...`: texto plano, sin traza ni propiedades. | `LegacyErrorMiddleware.cs:22` concatena `"Error: " + ex.Message` y no pasa la excepción al logger. `InventarioService.cs:20` y `PedidoService.cs:25,38,75` usan interpolación `$"..."`, de modo que no hay *message template* ni propiedades estructuradas. |
| INC-008 | `GET /api/lab/lento?ms=800` tarda unos 800 ms, pero no hay ningún registro de esa duración. | Nada mide la duración de las peticiones. No existe un evento de finalización. |

Relaciones entre incidentes: INC-002 e INC-003 también provocan INC-004, porque toda excepción de negocio termina en el middleware *legacy*. INC-006 e INC-007 comparten causa, la falta de un logging estructurado con salida a archivo.
