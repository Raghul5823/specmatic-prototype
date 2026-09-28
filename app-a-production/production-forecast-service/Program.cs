using ProductionForecastService;
using Prototype.ServiceDefaults;

var builder = WebApplication.CreateBuilder(args);
builder.AddPrototypeDefaults();
builder.AddDownstreamClient<IWellRegistryClient, WellRegistryClient>("Downstream:WellRegistryBaseUrl");
builder.AddDownstreamClient<IChangeRequestClient, ChangeRequestClient>("Downstream:ChangeRequestBaseUrl");
builder.Services.AddSingleton<IForecastRepository, InMemoryForecastRepository>();
builder.Services.AddScoped<ForecastService>();

var app = builder.Build();
app.UsePrototypeDefaults();
app.MapForecastEndpoints();
app.Run();

public partial class Program;
