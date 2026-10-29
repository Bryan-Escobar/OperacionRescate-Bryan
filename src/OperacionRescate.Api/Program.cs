using OperacionRescate.Api.Middleware;
using OperacionRescate.Api.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddControllers();

builder.Services.AddSingleton<IInventarioService, InventarioService>();
builder.Services.AddSingleton<IPedidoService, PedidoService>();

var app = builder.Build();

app.UseMiddleware<LegacyErrorMiddleware>();

app.MapControllers();

app.Run();

public partial class Program { }
