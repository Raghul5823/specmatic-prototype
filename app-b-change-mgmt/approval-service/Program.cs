using ApprovalService;
using Prototype.ServiceDefaults;

var builder = WebApplication.CreateBuilder(args);
builder.AddPrototypeDefaults();
builder.Services.AddSingleton<IApprovalRepository, InMemoryApprovalRepository>();
builder.Services.AddSingleton<ApprovalPolicy>();

var app = builder.Build();
app.UsePrototypeDefaults();
app.MapApprovalEndpoints();
app.Run();

public partial class Program;
