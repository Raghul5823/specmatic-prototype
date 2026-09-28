using Prototype.ServiceDefaults;
using WellRegistryService;

var builder = WebApplication.CreateBuilder(args);
builder.AddPrototypeDefaults();
builder.Services.AddSingleton<IWellRepository, InMemoryWellRepository>();
builder.Services.AddSingleton<WellService>();

var app = builder.Build();
app.UsePrototypeDefaults();
app.MapWellEndpoints();
app.Run();

public partial class Program;
