using System.Diagnostics;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

namespace Prototype.ContractTesting;

/// <summary>Repository locations used by the provider contract tests.</summary>
public static class Repo
{
    /// <summary>The prototype root (the folder that contains SpecmaticPrototype.sln).</summary>
    public static string Root { get; } = FindRoot();

    /// <summary>Debug or Release, taken from where this test assembly was built.</summary>
    public static string Configuration { get; } =
        AppContext.BaseDirectory.Contains($"{Path.DirectorySeparatorChar}Release{Path.DirectorySeparatorChar}") ? "Release" : "Debug";

    /// <summary>Where Specmatic reports go: results/&lt;CONTRACT_TEST_RESULTS&gt;, default results/pipeline/contract-tests.</summary>
    public static string ResultsDir =>
        Path.Combine(Root, "results", Environment.GetEnvironmentVariable("CONTRACT_TEST_RESULTS") ?? Path.Combine("pipeline", "contract-tests"));

    private static string FindRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "SpecmaticPrototype.sln")))
                return dir.FullName;
        throw new InvalidOperationException($"SpecmaticPrototype.sln not found above {AppContext.BaseDirectory}");
    }
}

/// <summary>
/// Runs a service's own build output (bin/&lt;config&gt;/net10.0/&lt;Assembly&gt;.dll) as a separate process on a
/// fixed port, waits for /readiness, and kills it on Dispose.
/// </summary>
public sealed class ServiceProcess : IDisposable
{
    private readonly Process _process;
    private readonly StringBuilder _log = new();

    private ServiceProcess(Process process) => _process = process;

    public static ServiceProcess Start(string projectDir, string assemblyName, int port,
        IReadOnlyDictionary<string, string>? environment = null)
    {
        if (IsListening(port))
            throw new InvalidOperationException($"Port {port} is already in use. Stop the running service first (scripts/stop-services.ps1).");

        var bin = Path.Combine(Repo.Root, projectDir, "bin", Repo.Configuration, "net10.0");
        var dll = Path.Combine(bin, assemblyName + ".dll");
        if (!File.Exists(dll))
            throw new FileNotFoundException("Service build output not found. Build the solution first.", dll);

        var info = new ProcessStartInfo("dotnet")
        {
            WorkingDirectory = bin,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        info.ArgumentList.Add(dll);
        info.ArgumentList.Add("--urls");
        info.ArgumentList.Add($"http://localhost:{port}");
        foreach (var (key, value) in environment ?? new Dictionary<string, string>())
            info.Environment[key] = value;

        var service = new ServiceProcess(Process.Start(info)!);
        service._process.OutputDataReceived += (_, e) => service.Append(e.Data);
        service._process.ErrorDataReceived += (_, e) => service.Append(e.Data);
        service._process.BeginOutputReadLine();
        service._process.BeginErrorReadLine();
        service.WaitForReadiness(port, TimeSpan.FromSeconds(30));
        return service;
    }

    private void Append(string? line)
    {
        if (line is null) return;
        lock (_log) _log.AppendLine(line);
    }

    private void WaitForReadiness(int port, TimeSpan timeout)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (_process.HasExited)
                throw new InvalidOperationException($"Service exited with code {_process.ExitCode}:\n{_log}");
            try
            {
                if (http.GetAsync($"http://localhost:{port}/readiness").GetAwaiter().GetResult().IsSuccessStatusCode)
                    return;
            }
            catch (HttpRequestException) { }
            catch (TaskCanceledException) { }
            Thread.Sleep(300);
        }
        Dispose();
        throw new TimeoutException($"Service on port {port} not ready after {timeout.TotalSeconds}s:\n{_log}");
    }

    private static bool IsListening(int port)
    {
        try
        {
            using var client = new TcpClient();
            client.Connect("127.0.0.1", port);
            return true;
        }
        catch (SocketException) { return false; }
    }

    public void Dispose()
    {
        try
        {
            if (!_process.HasExited)
            {
                _process.Kill(entireProcessTree: true);
                _process.WaitForExit(5000);
            }
        }
        catch (InvalidOperationException) { }
        _process.Dispose();
    }
}

/// <summary>Result of one Specmatic run, with a short summary for assertion messages.</summary>
public sealed record SpecmaticRun(int ExitCode, string Output, string ReportDir)
{
    public string Summary
    {
        get
        {
            var lines = Output.Split('\n').Select(l => l.TrimEnd('\r')).ToList();
            var summary = new List<string> { $"Specmatic exit code {ExitCode}; reports in {ReportDir}" };
            summary.AddRange(lines.Where(l => Regex.IsMatch(l, @"Tests run:|API Coverage reported")));
            var failures = lines.FindIndex(l => l.Contains("Unsuccessful Scenarios"));
            if (failures >= 0) summary.AddRange(lines.Skip(failures).Take(30));
            return string.Join(Environment.NewLine, summary);
        }
    }
}

/// <summary>Runs Specmatic in Docker with the same settings as scripts/run-provider-test.ps1.</summary>
public static class Specmatic
{
    public static string Image => Environment.GetEnvironmentVariable("SPECMATIC_IMAGE") ?? "specmatic/specmatic:2.55.0";
    private const string TestToken = "test-token-123";

    /// <summary>
    /// Provider contract test. Either <paramref name="spec"/> (path under contracts/) with <paramref name="port"/>,
    /// or a v3 <paramref name="config"/> (path under the prototype root) that names the system under test.
    /// </summary>
    /// <param name="timeoutMs">Specmatic's per-request timeout (default 6000). With mocked dependencies it must be
    /// LARGER than the service's own downstream timeout, or a slow mock makes Specmatic call the provider unreachable.</param>
    public static SpecmaticRun Test(string name, string? spec = null, int port = 0, string? config = null, int timeoutMs = 0)
    {
        var reportDir = Path.Combine(Repo.ResultsDir, name);
        DeleteDirectory(reportDir);
        Directory.CreateDirectory(reportDir);
        var work = "/work/" + Path.GetRelativePath(Repo.Root, reportDir).Replace('\\', '/');

        var args = BaseArgs(work);
        args.AddRange([Image, "test"]);
        if (config is not null) args.Add($"--config=/work/{config.Replace('\\', '/')}");
        else
        {
            args.Add($"/work/contracts/{spec}");
            args.Add($"--testBaseURL=http://host.docker.internal:{port}/v2");
        }
        args.Add($"--junitReportDir={work}/junit");
        if (timeoutMs > 0) args.Add($"--timeout-in-ms={timeoutMs}");

        var (exit, output) = Run("docker", args, TimeSpan.FromMinutes(10));
        File.WriteAllText(Path.Combine(reportDir, "console.txt"), output.Replace(Repo.Root, "."));
        return new SpecmaticRun(exit, output, Path.GetRelativePath(Repo.Root, reportDir));
    }

    /// <summary>
    /// Starts the `dependencies` mocks of a v3 config (`specmatic mock --config`) until disposed.
    /// <paramref name="warmUpUrls"/>: one real example request (GET) per mock, sent before the test starts.
    /// </summary>
    public static IDisposable StartDependencyMocks(string name, string config, int[] ports, params string[] warmUpUrls)
    {
        var container = $"ct-deps-{name}";
        Directory.CreateDirectory(Path.Combine(Repo.Root, "results", "specmatic-work"));
        Run("docker", ["container", "rm", "--force", container], TimeSpan.FromSeconds(30));
        var args = new List<string> { "run", "-d", "--name", container };
        foreach (var p in ports) args.AddRange(["-p", $"{p}:{p}"]);
        args.AddRange(BaseArgs("/work/results/specmatic-work").Skip(2)); // skip "run --rm"
        args.AddRange([Image, "mock", $"--config=/work/{config.Replace('\\', '/')}"]);
        var (exit, output) = Run("docker", args, TimeSpan.FromMinutes(2));
        if (exit != 0) throw new InvalidOperationException($"Could not start dependency mocks: {output}");

        var deadline = DateTime.UtcNow.AddSeconds(90);
        while (DateTime.UtcNow < deadline)
        {
            var (_, logs) = Run("docker", ["logs", container], TimeSpan.FromSeconds(30));
            if (logs.Contains("Press Ctrl"))
            {
                WarmUp(ports, warmUpUrls);
                return new Mocks(container);
            }
            Thread.Sleep(500);
        }
        new Mocks(container).Dispose();
        throw new TimeoutException($"Dependency mocks {container} did not start within 90s.");
    }

    /// <summary>
    /// The first request to a freshly started mock can be slow under load (Phase 7: up to 55 s inside a full
    /// pipeline run on Docker Desktop, about 2 s in isolation). So: wait for each mock's health endpoint, then send one
    /// real example request per mock, before the service under test is exercised.
    /// </summary>
    private static void WarmUp(IEnumerable<int> ports, IEnumerable<string> urls)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(90) };
        http.DefaultRequestHeaders.Add("Authorization", $"Bearer {TestToken}");
        // 1. Health: the mock answers /actuator/health at its root (not under the /v2 base path).
        foreach (var port in ports)
        {
            var deadline = DateTime.UtcNow.AddSeconds(60);
            var ready = false;
            while (!ready && DateTime.UtcNow < deadline)
            {
                try { ready = http.GetAsync($"http://localhost:{port}/actuator/health").GetAwaiter().GetResult().IsSuccessStatusCode; }
                catch (HttpRequestException) { }
                catch (TaskCanceledException) { }
                if (!ready) Thread.Sleep(500);
            }
        }
        // 2. One real example request per mock, so the first call from the service is not the cold one.
        foreach (var url in urls)
        {
            try { http.GetAsync(url).GetAwaiter().GetResult(); }
            catch (HttpRequestException) { }
            catch (TaskCanceledException) { }
        }
    }

    private sealed class Mocks(string container) : IDisposable
    {
        public void Dispose()
        {
            var (_, logs) = Run("docker", ["logs", container], TimeSpan.FromSeconds(30));
            Directory.CreateDirectory(Repo.ResultsDir);
            File.WriteAllText(Path.Combine(Repo.ResultsDir, $"{container}.log.txt"), logs.Replace(Repo.Root, "."));
            Run("docker", ["container", "rm", "--force", container], TimeSpan.FromSeconds(30));
        }
    }

    /// <summary>
    /// Deletes a previous run's report folder. It can hold Specmatic's git clone of the contracts (.specmatic/repos),
    /// whose pack files git marks read-only on Windows; Directory.Delete alone throws on those (Phase 7 finding).
    /// </summary>
    private static void DeleteDirectory(string path)
    {
        if (!Directory.Exists(path)) return;
        foreach (var file in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories))
            File.SetAttributes(file, FileAttributes.Normal);
        Directory.Delete(path, recursive: true);
    }

    private static List<string> BaseArgs(string workDir) =>
    [
        "run", "--rm",
        // Resolve host.docker.internal from /etc/hosts: Docker Desktop's DNS was slow (Phase 3 finding).
        "--add-host", "host.docker.internal:host-gateway",
        "-e", $"bearerAuth={TestToken}",
        "-v", $"{Repo.Root}:/work",
        "-v", $"{Path.Combine(Repo.Root, "contracts")}:/work/contracts:ro",
        "-w", workDir,
    ];

    private static (int ExitCode, string Output) Run(string file, IEnumerable<string> args, TimeSpan timeout)
    {
        var info = new ProcessStartInfo(file)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        foreach (var a in args) info.ArgumentList.Add(a);
        using var process = Process.Start(info)!;
        var output = new StringBuilder();
        process.OutputDataReceived += (_, e) => { if (e.Data is not null) lock (output) output.AppendLine(e.Data); };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) lock (output) output.AppendLine(e.Data); };
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        if (!process.WaitForExit(timeout))
        {
            process.Kill(entireProcessTree: true);
            return (-1, output + $"\nTimed out after {timeout}.");
        }
        process.WaitForExit();
        lock (output) return (process.ExitCode, output.ToString());
    }
}
