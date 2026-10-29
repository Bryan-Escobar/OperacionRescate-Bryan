# Operación Rescate — Distribuciones del Pacífico

Distribuciones del Pacífico necesita poner en línea una API para consultar su inventario y registrar pedidos. El equipo anterior dejó una primera versión funcionando a medias, con varios incidentes reportados por operaciones. Tu tarea es diagnosticar el comportamiento actual, corregirlo y dejar la API lista para producción.

La solución está construida con ASP.NET Core sobre .NET 10, usa controladores y mantiene los datos en memoria.

## Requisitos

- SDK de .NET 10.
- Git.
- `curl` para probar los endpoints (opcional).

## Restaurar, ejecutar y probar

Desde la raíz del repositorio:

```bash
dotnet restore
dotnet build
dotnet test
dotnet run --project src/OperacionRescate.Api --urls http://localhost:5000
```

El perfil `http` de `launchSettings.json` también publica la API en `http://localhost:5000`.

La API no usa Swagger. Los servicios se pueden probar con `curl` o con cualquier cliente HTTP.

## Contrato de la API

Puerto: `5000`. Todas las respuestas JSON usan `camelCase`. La búsqueda de SKU no distingue mayúsculas de minúsculas.

| Método y ruta | Descripción | Respuestas esperadas |
|---|---|---|
| `GET /api/inventario` | Lista todos los productos | 200 |
| `GET /api/inventario/{sku}` | Consulta un producto | 200, 404 |
| `POST /api/pedidos` | Crea un pedido y descuenta stock | 201 con `Location`, 400, 404, 409 |
| `GET /api/pedidos/{id}` | Consulta un pedido | 200, 404 |
| `GET /api/lab/excepcion` | Fuerza una excepción no controlada | 500 |
| `GET /api/lab/lento?ms=N` | Simula una operación lenta (N entre 0 y 2000) | 200 `{"esperadoMs": N}` |

### Cuerpos

Producto:

```json
{ "sku": "LAP-001", "nombre": "Laptop Pro 14", "stock": 500, "precio": 899.90 }
```

Solicitud de pedido:

```json
{
  "clienteId": "CLI-001",
  "items": [
    { "sku": "LAP-001", "cantidad": 2 }
  ]
}
```

Los campos desconocidos del JSON se ignoran. Pedido creado:

```json
{
  "id": "<guid>",
  "clienteId": "CLI-001",
  "estado": "Confirmado",
  "total": 1799.80,
  "items": [
    { "sku": "LAP-001", "cantidad": 2, "precioUnitario": 899.90 }
  ]
}
```

### Reglas de negocio esperadas

- `cantidad` debe ser un entero mayor que cero.
- `items` no puede estar vacío.
- `clienteId` es obligatorio.
- El SKU debe existir; si no existe, la respuesta es 404.
- Debe haber stock suficiente para todos los ítems antes de modificar cualquier producto; si falta stock, la respuesta es 409 y el pedido es atómico.
- Una cantidad inválida nunca debe alterar el inventario.

### Formato de errores esperado

Los errores de la versión final deben usar `application/problem+json` con `type`, `title`, `status`, `detail` y `correlationId`. El `correlationId` debe coincidir con la cabecera `X-Correlation-ID`.

- 400: error de validación o JSON malformado.
- 404: recurso inexistente.
- 409: stock insuficiente.
- 500: error inesperado, con un mensaje genérico y sin trazas, nombres de tipos ni rutas.

## Datos semilla

| SKU | Nombre | Stock | Precio |
|---|---|---|---|
| LAP-001 | Laptop Pro 14 | 500 | 899.90 |
| MOU-002 | Mouse inalámbrico | 1000 | 19.90 |
| TEC-003 | Teclado mecánico | 300 | 59.00 |
| MON-004 | Monitor 27 pulgadas | 150 | 249.50 |
| SSD-005 | Disco SSD 1 TB | 8 | 109.00 |

## Incidentes reportados

| Incidente | Síntoma observado | Qué investigar |
|---|---|---|
| INC-001 | Consultar un producto inexistente devuelve un error incorrecto. | Excepciones de recurso no encontrado y códigos HTTP. |
| INC-002 | Un pedido con cantidad cero provoca un error inesperado. | Validaciones y excepciones de negocio. |
| INC-003 | Un pedido superior al inventario disponible falla sin explicación clara. | Reglas de negocio y manejo de conflictos. |
| INC-004 | Una excepción interna expone detalles técnicos. | Manejo global de excepciones y respuestas seguras. |
| INC-005 | No es posible relacionar una petición con su registro de error. | Correlation ID y propagación del contexto. |
| INC-006 | Los registros aparecen en consola, pero no se almacenan correctamente. | Configuración de Serilog y escritura en archivos. |
| INC-007 | Los logs contienen mensajes difíciles de analizar automáticamente. | Logging estructurado y formato JSON. |
| INC-008 | El equipo no puede identificar qué petición tardó demasiado. | Medición del tiempo de procesamiento. |

## Validador

El repositorio incluye dos validadores. Ejecútalos con la API en marcha.

En Linux, macOS o Git Bash (requiere `curl` y `jq`):

```bash
bash validador/validar.sh http://localhost:5000 ./logs
```

En Windows con PowerShell 7:

```powershell
pwsh validador/validar.ps1 -BaseUrl http://localhost:5000 -LogDir ./logs
```

El validador genera `reporte-validacion.json` en la raíz del repositorio.
