using ChangeRequestService;
using Prototype.ServiceDefaults;

var builder = WebApplication.CreateBuilder(args);
builder.AddPrototypeDefaults();
builder.AddDownstreamClient<IApprovalClient, ApprovalClient>("Downstream:ApprovalBaseUrl");
builder.AddDownstreamClient<IProductionForecastClient, ProductionForecastClient>("Downstream:ProductionForecastBaseUrl");
builder.Services.AddSingleton<IChangeRequestRepository, InMemoryChangeRequestRepository>();
builder.Services.AddScoped<ChangeRequestManager>();

var app = builder.Build();
app.UsePrototypeDefaults();
app.MapChangeRequestEndpoints();
app.Run();

public partial class Program;
