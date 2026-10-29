# Informe de diagnóstico — Operación Rescate

**Resultado:** el validador pasó de **11/100** con la API recibida a **100/100** en tres corridas consecutivas. `dotnet test` ejecuta **40 pruebas**, todas en verde.

**Evidencia:**

- Antes de corregir (commit `3db6ee7`): `evidencias/antes/`.
- Después de corregir: `evidencias/despues/`, `evidencias/validador-corrida-{1,2,3}.txt`, `evidencias/reporte-validacion.json`, `evidencias/dotnet-test.txt` y `evidencias/logs/`. El archivo `corrida-final-*.jsonl` contiene solo los eventos de la última corrida del validador.

## 1. Incidentes

| Inc. | Cómo lo reproduje | Causa raíz (archivo/línea, código recibido) | Corrección y justificación | Cómo lo verifiqué |
|---|---|---|---|---|
| **INC-001** | `GET /api/inventario/NOEXISTE-999` devolvía **500** `text/plain` con `KeyNotFoundException`. `GET /api/pedidos/no-existe` devolvía **204**. | `InventarioService.cs:30`: `_productos[sku]` lanza una excepción cuando la clave no existe. `PedidosController.cs:28`: `Ok(null)` produce 204. | `ObtenerPorSku` y `ObtenerPorId` lanzan `RecursoNoEncontradoException` (404). Así el servicio, que sabe que el recurso no existe, decide el tipo de error, y el manejador global decide el formato HTTP. | `ObtenerPorSku_Inexistente_LanzaRecursoNoEncontrado404`, `ObtenerPorId_Inexistente_Lanza404`, `ProductoInexistente_Devuelve404ProblemJson`; validador T02 y T08. |
| **INC-002** | `cantidad:0` daba 500 (`DivideByZeroException`). `cantidad:-5` daba **201** y el stock **subía** a 505. `items:[]` daba 500. JSON malformado daba 500 (NRE). | `PedidoService.cs` no validaba nada. Línea 37: división entre `cantidadTotal = 0`. Línea 43: `Stock -= -5` suma. Línea 24: `First()` sobre una lista vacía. Sin `[ApiController]`, un cuerpo inválido llegaba como `null`. | `Validar()` se ejecuta **antes** de tocar el inventario: request, `clienteId`, `items`, `sku` y cantidad > 0, con `ValidacionException` (400). `[ApiController]` y un `InvalidModelStateResponseFactory` devuelven 400 problem+json ante JSON malformado o cantidades no enteras, sin los mensajes internos del deserializador. | `CrearPedido_CantidadNoPositiva_Lanza400SinAlterarStock` (0 y -5), `CrearPedido_SinItemsOSinCliente_Lanza400`, `PedidoInvalido_Devuelve400ProblemJson` (malformado, 1.5, 0); validador T04, T05 y T07. |
| **INC-003** | Un pedido de 9 `SSD-005` (stock 8) daba 500 "Error al procesar el pedido" y el stock quedaba en **-1**. `[LAP-001 x1, SSD-005 x9]` fallaba y aun así descontaba LAP-001. | `PedidoService.cs:40-53`: descuenta primero y valida después (`Stock < 0`) con un `Exception` genérico, sin revertir. El pedido no era atómico. | Orden nuevo dentro del `lock`: (1) todos los SKU existen (404), (2) el stock alcanza, **agrupando por SKU** para que un SKU repetido no lo supere (409 `StockInsuficienteException` con detalle), (3) recién entonces se descuenta. Ningún rechazo modifica el inventario. | `CrearPedido_StockInsuficiente_Lanza409YEsAtomico`, `CrearPedido_SkuRepetidoQueSuperaStock_Lanza409`, `CrearPedido_ExactamenteElStockDisponible_SeAcepta`; validador T03 y T06; `evidencias/despues/INC-003.txt`. |
| **INC-004** | `GET /api/lab/excepcion` devolvía la traza, `System.InvalidOperationException` y `C:\Users\...\LabController.cs:line 11`. | `LegacyErrorMiddleware.cs:28`: `WriteAsync(ex.ToString())`. | Se eliminó `LegacyErrorMiddleware`. `UseExceptionHandler` y `GlobalExceptionHandler` (`IExceptionHandler`) convierten `AppException` a su código y cualquier otra excepción a un 500 **genérico**, siempre como `application/problem+json` con `correlationId`. El detalle va solo a los logs. | `ExcepcionDeLaboratorio_Devuelve500SeguroConCorrelationId`, `ExcepcionNoManejada_SeRegistraUnaVezYDevuelve500Seguro`; validador T09. |
| **INC-005** | Ninguna respuesta traía `X-Correlation-ID` y el error de consola no se podía asociar a una petición. | No existía ningún mecanismo de correlación (`Program.cs`). | `RequestDiagnosticMiddleware` acepta el ID solo si es un GUID 8-4-4-4-12 exacto (un valor, 36 caracteres, `Guid.TryParseExact "D"`); en otro caso genera uno nuevo. Lo publica en `LogContext`, en `HttpContext.Items` (de donde lo toma el problem+json) y en la cabecera de **todas** las respuestas. | `CorrelationIdValido_...`, `CorrelationIdInvalido_SeGeneraUnoNuevo` (6 casos hostiles), `CorrelationIdMuyLargoOMultiple_...`, `PeticionesSimultaneas_NoMezclanContexto`; validador C01 a C04. |
| **INC-006** | Los logs solo salían por consola. No existía `logs/` y el validador fallaba L01 a L09. | Logging por defecto de ASP.NET Core, sin Serilog ni sink de archivo. | Serilog (`AddSerilog` + `ReadFrom.Configuration`) con un sink File `logs/api-.json`, rotación **diaria**, 7 archivos retenidos, límite de 50 MB por archivo y `shared` para poder leer mientras se escribe. | `Logs_SeEscribenEnArchivoJsonLinesConLaCorrelacion`; validador L01. |
| **INC-007** | La consola mostraba `fail: ... Error: The given key...`: texto plano, sin traza ni propiedades. | `LegacyErrorMiddleware.cs:22` concatenaba y no pasaba `ex` al logger. Los servicios usaban `$"..."` (`InventarioService.cs:20`, `PedidoService.cs:25,38,75`). | *Message templates* en todos los logs. `JsonLinesFormatter` propio: el formateador JSON por defecto anida las propiedades en `"Properties"` y usa la hora local, así que este escribe un objeto por línea con las propiedades en el nivel superior, `Timestamp` UTC con `Z` y `Exception` completa (`ex.ToString()`). | `Formato_UnaLineaConPropiedadesEnNivelSuperiorYTiposCorrectos`, `Excepcion_SeEscribeCompletaEnUnaSolaLinea`; validador L02, L03 y L07. |
| **INC-008** | `GET /api/lab/lento?ms=800` no dejaba ningún registro de su duración. | Nada medía el tiempo. | El middleware mide con `TimeProvider.GetTimestamp/GetElapsedTime` (reloj monotónico, inyectable) y escribe `ElapsedMs` (double) solo en el evento de finalización. | `ElapsedMs_SeMideConElRelojInyectado` (reloj falso, 250 ms exactos); validador L05 (300 ms y 800 ms reales). |

## 2. Decisiones de diseño del middleware

**Pipeline:** `RequestDiagnosticMiddleware`, luego `UseExceptionHandler`, luego `UseStatusCodePages` y por último `MapControllers`.

1. **El middleware va antes que el manejador global.** Envuelve al manejador, así que cuando `await _next()` vuelve, el manejador ya escribió la respuesta y `Response.StatusCode` es el código **final** (404, 409, 500…). Así el evento de finalización registra lo que recibió el cliente.
2. **Cabecera en `OnStarting`.** Las cabeceras solo se pueden modificar antes de que empiece la respuesta. Además, `ExceptionHandlerMiddleware` hace `Response.Clear()`, que borraría una cabecera puesta al inicio. El callback de `OnStarting` se ejecuta justo antes de enviar, también en las respuestas de error.
3. **Una excepción, un registro.** El manejador global solo construye la respuesta y no registra nada. El framework tiene sus diagnósticos desactivados (`SuppressDiagnosticsCallback`). El middleware registra la excepción una sola vez, leyendo `IExceptionHandlerFeature.Error`, y solo si el resultado es 5xx. Un 400/404/409 no es un error interno: solo produce el evento de finalización en **Warning**.
4. **Fallos (R7).** Si una excepción escapa del manejador (por ejemplo, porque la respuesta ya empezó), el `catch` la registra una vez y **no vuelve a llamar a `_next`**. Si la respuesta no empezó, escribe un 500 problem+json genérico. Si ya empezó, no puede reemplazarla y hace `context.Abort()` para que el cliente no tome como válida una respuesta truncada. El evento de finalización se escribe en `finally`, así que siempre hay exactamente uno.
5. **Contexto (R6).** `LogContext.PushProperty` usa `AsyncLocal`, de modo que `CorrelationId` y `LabRunId` llegan a todos los eventos de la petición, incluidos los de servicios y controladores, y nunca a los de otra petición simultánea. `LabRunId` se valida con `^[A-Za-z0-9._-]{1,64}$`; si no pasa, se usa `sin-run`.
6. **Privacidad (R8).** `RequestPath = PathBase + Path`, sin query string. No se registran cuerpos ni cabeceras. `Microsoft.*` queda en Warning para que el framework no registre las URL completas, que incluyen `?token=`. El validador lo confirma en L08.
7. **Niveles.** 2xx/3xx van como Information, 4xx como Warning, y 5xx o una excepción como Error.
8. **Ruta de logs.** `dotnet run --project src/OperacionRescate.Api` usa como directorio de trabajo la carpeta del proyecto, que es lo que se ve en `evidencias/antes/consola.txt`. Por eso el sink usa `../../logs/api-.json`: los archivos quedan en `logs/` de la raíz, que es la ruta que usa el validador (`-LogDir ./logs`) y que ya está en `.gitignore`.

## 3. Cómo ejecutar el validador

```powershell
dotnet run --project src/OperacionRescate.Api --urls http://localhost:5000
pwsh -ExecutionPolicy Bypass -File validador/validar.ps1 -BaseUrl http://localhost:5000 -LogDir ./logs
```

En este equipo hizo falta `-ExecutionPolicy Bypass`, que se aplica solo a ese proceso, porque el script no está firmado. El validador no se modificó: `git diff 1958fa7 HEAD -- validador` está vacío.

## 4. Declaración de uso de herramientas de IA

Usé **Claude Code** (Anthropic) como asistente para:

- leer la guía y el código recibido;
- reproducir los incidentes y ubicar sus causas raíz;
- proponer e implementar las correcciones, el middleware, la configuración de Serilog y las pruebas unitarias;
- redactar este informe.

Revisé el código resultante y debo poder explicarlo línea por línea en la defensa.
