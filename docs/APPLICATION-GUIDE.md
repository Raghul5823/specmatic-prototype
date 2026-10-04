# Application Guide: what was built, how it is designed, and why

This guide explains the whole prototype, from the goal down to individual files. It is written for a QA or development reader who has not seen the project before. Read it top to bottom: each section builds on the one before. The README is the evaluation log (what we ran and what we found). This guide is the map of the system itself.

---

## 1. The main goal

The project answers one question with evidence: **is Specmatic (open-source edition) good enough to be our contract-testing tool?** Our real platform has Angular micro-frontends (MFEs) calling .NET 10 microservices, built and deployed through Azure DevOps pipelines, secured with OAuth2. In that kind of system most production incidents between teams are not bugs inside one service. They are **mismatches between services**: one team renames a field, changes a status code or tightens a rule, and another team's code silently breaks after deployment. Contract testing catches those mismatches **before** deployment, in each team's own pipeline, without standing up the whole system.

To evaluate that honestly we needed something realistic but small. So we built a miniature version of such a platform:
- two "applications" owned by different teams;
- four services that call each other inside an application and across applications, in both directions;
- a central contract repository;
- later, an Angular consumer and a pipeline.

Then we use Specmatic on it, deliberately break things, and record what Specmatic catches and what it doesn't. The final output is a **Go / Conditional Go / No-Go** recommendation in the README.

---

## 2. Key terms (with examples from this project)

**API contract.** A precise, written agreement about how one service may be called and what it will answer: the URL paths, the HTTP methods, the request fields and their types, the possible status codes, and the response fields. *Example:* "`GET /v2/wells/{wellId}` with `wellId` like `W-001` returns `200` with a well object containing `id`, `name`, `status`…, or `404` with a ProblemDetails body if the well does not exist."

**OpenAPI specification (spec).** The industry-standard file format (YAML or JSON) for writing an API contract. We use **OpenAPI 3.0.3**. *Example:* `contracts/specs/app-a-production/well-registry-service.yaml`. **Why OpenAPI:** it's the format .NET, Angular code generators, Azure API Management and Specmatic all understand, so one file serves many tools.

**Provider and consumer.** The **provider** is the service that *offers* an API, and the **consumer** is the code that *calls* it. *Example:* in interaction C1, `well-registry-service` is the provider and `production-forecast-service` is the consumer. A service can be both: production-forecast provides `/forecasts` and also consumes `/wells`.

**Contract test (provider side).** A test that sends real HTTP requests to the **running provider** and checks that every response matches the contract. Specmatic generates these tests from the spec. *Example:* Specmatic sends `GET /v2/wells/W-999` and checks that the answer is a `404` with a valid ProblemDetails body.

**Stub (also called mock or service virtualisation).** A fake server generated from the provider's contract, which a **consumer** calls in its own tests instead of the real provider. *Example:* the well-registry stub on port 9101 answers `GET /v2/wells/W-003` with the SHUT_IN well from an example. The real well-registry doesn't have to run. The stub also **checks the consumer's request**: `GET /v2/wells/WELL-1` is rejected because the id breaks the pattern `^W-\d{3}$`.

**Example.** A concrete request and response pair attached to a contract. **Inline examples** live inside the spec (a request example and a response example with the same name, e.g. `GET_W001`). **External examples** are separate JSON files in a folder named `<spec-name>_examples`. Examples do two jobs at once: they become **provider tests** and **stub responses**.

**Consumer-contributed example.** An external example written by the *consumer* team, describing exactly the interaction it relies on. Its file name starts with the consumer, e.g. `production-forecast__get_well_W-003_shut_in.json`. **Why it matters:** the provider runs it as a contract test, so if the provider breaks something this consumer relies on, *the provider's own pipeline fails*. That is how Specmatic gets close to "consumer-driven" contract testing (the Pact model).

**Backward compatibility.** A new version of a contract is backward compatible if every existing consumer still works. *Example:* adding a new optional field is compatible; renaming a required response field is a **breaking** change. Specmatic has a `backward-compatibility-check` command for this (Phase 5).

**ProblemDetails (RFC 9457).** A standard JSON format for HTTP errors, with the content type `application/problem+json`. *Example:* `{"type": "...", "title": "Not Found", "status": 404, "detail": "Well W-999 does not exist."}`. Validation errors add an `errors` map, e.g. `{"errors": {"name": ["name is required (1-100 characters)."]}}`. **Why:** one error shape for every service and every error means it can be written into the contract once and checked automatically.

**Bearer token.** The `Authorization: Bearer <token>` header used by OAuth2. Our prototype replaces the real identity provider with a fixed test token, `test-token-123`. **Why:** we want to see how Specmatic *handles* auth, not test OAuth itself.

**Base path.** A common URL prefix in front of all business endpoints. Ours is **`/v2`**, matching the ingress routes of our real Helm setup. *Example:* `http://localhost:5101/v2/wells`.

**Health probes.** `/liveness` ("is the process alive?") and `/readiness` ("can it take traffic?"). Kubernetes calls these, not API consumers, so they are **not** part of the contracts.

**API coverage.** Specmatic's measure of how many documented *responses* (path + method + status) were exercised by tests. *Example:* well-registry documents 10 responses; with only happy-path examples, 4 were tested (40%); after adding error examples, all 10 were (100%). It is **not** code coverage.

---

## 3. The business story (why oil & gas, and what the services do)

We gave the prototype a realistic domain so the data and rules mean something. **Application A, "Production"**, knows about oil wells and predicts how much oil they will produce. **Application B, "Change Management"**, handles requests to change a well's operation (for example, opening a choke to raise output) and decides whether each change is approved. The two applications are owned by different teams and depend on each other. This is exactly the situation where contract testing pays off.

| Service | App | Port | What it does |
|---|---|---|---|
| **well-registry-service** | A | 5101 | The master list of wells. Lists wells (optionally by status), returns one well by id, registers a new well. Each well has an id like `W-001`, a name, an oil field, a status (`ACTIVE`, `SHUT_IN`, `ABANDONED`), coordinates, a spud date (when drilling started) and a daily capacity in barrels per day (bbl/d). |
| **production-forecast-service** | A | 5102 | Creates production forecasts. For a well it calculates the effective daily capacity (base capacity + all *approved* change requests) and projects monthly volumes with exponential decline: `volume(month m) = effective × 30 × (1 − decline%)^m`. |
| **change-request-service** | B | 5201 | Raises change requests against wells (`CHOKE_CHANGE`, `WORKOVER`, `SHUT_IN`) with a capacity delta (e.g. +150 bbl/d). Optionally links a request to a forecast. Each request is decided immediately by approval-service. |
| **approval-service** | B | 5202 | Decides change requests automatically: if `abs(capacityDeltaBbl) <= 500` it is **APPROVED** (within delegated authority), otherwise **REJECTED** (needs manual review). |

**One flow end to end, with real numbers.** A planner asks production-forecast to forecast well **W-001** for 3 months at 5% monthly decline (`POST /v2/forecasts`):
1. production-forecast calls **well-registry** (`GET /v2/wells/W-001`) and learns that the well is ACTIVE with a base capacity of **1200** bbl/d.
2. It then calls **change-request** in the *other* application (`GET /v2/change-requests?wellId=W-001&status=APPROVED`) and finds one approved change, CR-1001 (**+150**).
3. Effective capacity is therefore **1350** bbl/d. The monthly volumes are 1350×30 = **40,500**, then 38,475, then 36,551.3, for a total of **115,526.3** barrels.

Every number in this flow is fixed seed data, so tests and examples can rely on it.

---

## 4. Architecture: the four calls and why they look like this

```
                 App A: Production                         App B: Change Management
   ┌───────────────────────────────────┐        ┌──────────────────────────────────────┐
   │ production-forecast ──C1──► well-  │        │ change-request ──C2──► approval      │
   │     (5102)            GET  registry│        │    (5201)      POST     (5202)       │
   │        │  ▲            /wells/{id} │        │      │  ▲      /approvals            │
   └────────┼──┼────────────────────────┘        └──────┼──┼────────────────────────────┘
            │  └──────────── C3: GET /forecasts/{id} ───┘  │   (cross-app, B → A)
            └─────────────── C4: GET /change-requests ─────┘   (cross-app, A → B)
```

| # | Consumer → Provider | Endpoint | Type | Fields the consumer actually uses |
|---|---|---|---|---|
| C1 | production-forecast → well-registry | `GET /v2/wells/{wellId}` | intra-app | `id, name, status, dailyCapacityBbl` |
| C2 | change-request → approval | `POST /v2/approvals` | intra-app | sends `changeRequestId, type, capacityDeltaBbl`; reads `id, decision, reason` |
| C3 | change-request → production-forecast | `GET /v2/forecasts/{forecastId}` | **cross-app B→A** | `id, wellId` |
| C4 | production-forecast → change-request | `GET /v2/change-requests?wellId&status=APPROVED` | **cross-app A→B** | `id, wellId, status, capacityDeltaBbl` |

**Why exactly these four calls:** together they cover every case the evaluation must answer. C1 and C2 are calls inside one team's application (Phase 4). C3 and C4 cross team boundaries in **both** directions (Phase 5). That's the hardest case in a real organisation, because the two teams release independently.

**Why the two cross-app calls can never loop:** each direction uses a *different* endpoint, and the endpoint being called makes no outgoing calls. `POST /forecasts` calls `GET /change-requests`, which only reads its own data. `POST /change-requests` calls `GET /forecasts/{id}`, which also only reads its own data. The endpoints that fan out (the two POSTs) are never called by another service. A loop would need A→B→A on the *same* path, and this design rules that out.

**Why fixed ports:** every script, stub and test knows where each service lives without a lookup. Provider ports are 51xx (App A) and 52xx (App B). The Specmatic stubs for them use 91xx and 92xx, so a stub never collides with the real service.

---

## 5. Folder structure, file by file

```
Specmatic Prototype/                      ← prototype git repo (public)
├─ README.md                              evaluation log: checklist, phases, findings, scorecard
├─ LICENSE, .gitignore, nuget.config      MIT licence; what git ignores; NuGet = nuget.org only
├─ SpecmaticPrototype.sln                 builds all 8 projects with one command
├─ docs/APPLICATION-GUIDE.md              this guide
├─ shared/Prototype.ServiceDefaults/      plumbing shared by every service
├─ app-a-production/
│   ├─ well-registry-service/             provider (C1)
│   ├─ well-registry-service.Tests/       xUnit tests of its INTERNAL layers
│   ├─ production-forecast-service/       consumer (C1, C4) and provider (C3)
│   └─ production-forecast-service.Tests/ consumer contract tests vs the well-registry STUB
├─ app-b-change-mgmt/
│   ├─ change-request-service/            consumer (C2, C3) and provider (C4)
│   ├─ change-request-service.Tests/      consumer contract tests vs the approval STUB
│   └─ approval-service/                  provider (C2)
├─ mfe/well-mfe/                          Angular 21 micro-frontend (consumer C5): generated client, Playwright tests
├─ specmatic/                             Specmatic config files (v3) owned by the services
├─ scripts/                               PowerShell automation (start/stop, tests, stubs, experiments)
├─ results/                               evidence of every run (reports, logs, summaries)
└─ contracts/                             ← SEPARATE git repo: the central contract repository
```

**Why two git repositories:** in a real organisation the contracts are shared by many teams and have their own review and versioning rules, while each service's code belongs to one team. Keeping `contracts/` as its own repository (ignored by the root `.gitignore`) simulates that separation. Specs are versioned with tags (`v1`, `v1.1`), and service code never edits a spec in place.

### 5.1 Inside one service (well-registry as the example)
Every service has the same four-layer structure:

| File | Layer | What it holds | Why separate |
|---|---|---|---|
| `Program.cs` | startup | ~10 lines: add shared defaults, register classes, map endpoints, run | Keeps wiring in one obvious place. `public partial class Program;` lets tests host the app. |
| `Models.cs` | data shapes | `Well` (response) and `CreateWellRequest` (request) records, `WellStatus` enum | Request fields are all optional, so the service can report **every** missing field in one 400 instead of failing on the first. |
| `WellEndpoints.cs` | HTTP layer | the 3 routes under `/v2/wells`, status codes, ProblemDetails | Only translates HTTP ↔ method calls; no business rules here. |
| `WellService.cs` | business layer | validation rules (name 1–100 characters, latitude −90..90…), creating a well | Rules can be unit-tested without HTTP. |
| `WellRepository.cs` | data layer | `IWellRepository` + an in-memory list with 3 seed wells | The interface lets tests insert a recording fake. In-memory keeps the prototype self-contained (no database). |
| `appsettings.json` | config | port `5101`, expected token | Ports and tokens are config, not code. |

A request travels **endpoint → service → repository** and back. *Example:* `GET /v2/wells/W-001` → `WellEndpoints` checks the id pattern → `WellService.Get` → `IWellRepository.Get("W-001")` → the well is returned as `200`, or a `404` ProblemDetails.

**The consumers** (production-forecast and change-request) add two things. `Clients.cs` holds typed HTTP clients for each provider they call, e.g. `WellRegistryClient`. `Models.cs` holds a **consumer view** of each provider's data, e.g. `WellSummary(Id, Name, Status, DailyCapacityBbl)`, which has only the 4 fields it uses out of the provider's 8. **Why:** a consumer should depend only on what it uses. A provider change to an unused field must not break it, and that list of used fields is exactly what goes into `consumers.yaml`.

### 5.2 The shared library (`shared/Prototype.ServiceDefaults/ServiceDefaults.cs`)
One file gives every service identical behaviour:
- **Strict JSON:** `"123"` is not a number, `1` is not an enum value, `null` is not allowed for required fields, and a missing required field fails. **Why:** Specmatic's negative tests send exactly these mistakes, and a correct service must reject them with a 400 instead of quietly accepting them.
- **ProblemDetails for every error**, including unhandled exceptions, unknown routes and malformed JSON.
- **The test-token middleware:** every request except the probes must carry `Authorization: Bearer test-token-123`, otherwise it gets a 401.
- **`/liveness` and `/readiness`** at the root, with no auth.
- **`AddDownstreamClient`:** registers a consumer's HTTP client with its base URL (including `/v2/`), the bearer token and a 5-second timeout. **Why:** pointing a consumer at a Specmatic stub is then only a configuration change, e.g. `Downstream__WellRegistryBaseUrl=http://localhost:9101/v2/`.
- **Downstream error handling:** a provider that is down or returns the wrong shape becomes a clean **502** ProblemDetails, so a broken contract is visible.

---

## 6. The contracts repository (`contracts/`)

```
contracts/                                       (git tags: v1, v1.1)
├─ README.md                                     conventions, change rules, versioning rule
├─ consumers.yaml                                who relies on which endpoint and fields (our governance file)
├─ common/common.yaml                            shared ProblemDetails schema + 400/401/404/502 responses
└─ specs/
   ├─ app-a-production/
   │   ├─ well-registry-service.yaml             + well-registry-service_examples/        (10 files)
   │   └─ production-forecast-service.yaml       + production-forecast-service_examples/  (2 files)
   └─ app-b-change-mgmt/
       ├─ change-request-service.yaml            + change-request-service_examples/       (2 files)
       └─ approval-service.yaml                  + approval-service_examples/             (2 files)
```

**What is in each spec.** Each is an OpenAPI 3.0.3 file with:
- `servers: /v2`;
- a global `bearerAuth` security scheme;
- strict schemas: required fields, `pattern` for ids (`^W-\d{3}$`, `^F-\d{4}$`, `^CR-\d{4}$`, `^A-\d{4}$`), `enum` for statuses and types, min/max ranges, `format: date` / `date-time`;
- every error response (400, 401, and 404 where there is an id; 502 where the service calls others);
- a required `Location` header on every 201;
- named inline examples that match the seed data.

**The APIs: 4 specs, 8 paths, 10 operations.**

| Spec | Operation | Success | Errors in the contract |
|---|---|---|---|
| well-registry | `GET /wells?status=` (list) | 200 | 400, 401 |
| | `POST /wells` (create) | 201 + Location | 400, 401 |
| | `GET /wells/{wellId}` | 200 | 400, 401, 404 |
| production-forecast | `POST /forecasts` | 201 + Location | 400, 401, 502 |
| | `GET /forecasts/{forecastId}` | 200 | 400, 401, 404 |
| change-request | `GET /change-requests?wellId=&status=` | 200 | 400, 401 |
| | `POST /change-requests` | 201 + Location | 400, 401, 502 |
| | `GET /change-requests/{changeRequestId}` | 200 | 400, 401, 404 |
| approval | `POST /approvals` | 201 + Location | 400, 401 |
| | `GET /approvals/{approvalId}` | 200 | 400, 401, 404 |

**Examples: 33 in total.**
- 17 **inline** (provider-authored, inside the specs): well-registry 5, production-forecast 3, change-request 5, approval 4.
- 16 **external**:
  - 9 **consumer-contributed** (`production-forecast__…`, `change-request__…`): a happy path, a 404, a SHUT_IN well, an empty list, approve and reject.
  - 7 **provider-owned** (`provider__…`, added in v1.1): bad id, bad status and missing name (400); invalid token for all 3 operations and an empty token (401).

**`common/common.yaml`.** It defines ProblemDetails once:
- `type`, `title` and `status` are required;
- `errors` is **optional**, because a malformed body returns no field map (found in Phase 1);
- `traceId` is listed, because Specmatic treats response schemas as closed.

Every spec points to it with an external `$ref`. **Why:** one definition means one place to change it, and every service is held to the same error format.

**`consumers.yaml`.** This is our own map of interactions C1–C4. For each one it lists the consumer, the provider, the operation, the responses used, the **fields used** and the example files that belong to it. Specmatic does not read it. **Why it exists:** when a provider wants to change something, this file says *who* is affected and *which fields* they depend on. That is the part of consumer-driven testing that Specmatic does not track by itself.

**Versioning rule** (in the contracts README):
- **MAJOR** (`v2`) for a breaking change;
- **MINOR** (`v1.1`) for a backward-compatible addition: new examples, optional fields or endpoints.

Tags are annotated and never moved. `v1` is the first contract set, and `v1.1` added the provider error examples.

---

## 7. Specmatic configuration and the scripts

**`specmatic/*.yaml` (Specmatic config, version 3).** Each one tells Specmatic *what to run and how*:
- `well-registry.specmatic.yaml`: the **provider test** for well-registry, with the spec taken from the contracts folder and `schemaResiliencyTests: all` (generated positive and negative tests).
- `well-registry.mock.yaml` and `approval.mock.yaml`: the **stubs** for consumers, with `baseUrl: http://0.0.0.0:9000/v2`, so the stub serves `/v2/...` exactly like the real service.
- `production-forecast.specmatic.yaml` and `change-request.specmatic.yaml`: **provider test + mocked dependencies** for the cross-app providers. They pull specs from a **git source** (the central contract repo, cloned by Specmatic). `specmatic mock --config` starts the dependencies, and `specmatic test --config` tests the service.
- `production-forecast.mock.yaml` and `change-request.mock.yaml`: cross-app consumer stubs, also from the git source.

**Why the configs live with the services and not in `contracts/`:** how a team *uses* a contract (test or stub, ports, strictness) is that team's decision. The contract itself is shared.

**Scripts** (`scripts/`, PowerShell 5.1):

| Script | Purpose |
|---|---|
| `common.ps1` | the one place that lists every service: folder, DLL, port, spec path |
| `start-services.ps1` / `stop-services.ps1` | build and start services in the background, wait for `/readiness`, record PIDs; stop by PID or port |
| `smoke-test.ps1` | 17 plain HTTP checks (not contract tests) that the services and both cross-app chains work |
| `run-provider-test.ps1` | Specmatic provider test against a running service. Saves console, coverage, JUnit, HTML and a summary to `results/`; mounts `contracts/` read-only; adds the Docker DNS fix |
| `stub.ps1` | starts or stops a Specmatic stub on a fixed port (optionally strict, optionally with a config) and saves its request log |
| `break-experiment.ps1` | applies one deliberate code change, builds, runs xUnit and Specmatic (or the consumer tests against a stub), records whether each caught it, then restores the exact original bytes |
| `case1-break-experiments.ps1`, `case2-break-experiments.ps1` | the full experiment lists for Phases 3 and 4, plus summary tables |
| `deps.ps1` | starts or stops a provider's **dependency mocks** from its config (`specmatic mock --config`) |
| `compat-check.ps1` | Specmatic **backward-compatibility check** on a git checkout of the contract repo; records the exit code (0 = compatible, 1 = breaking) |
| `case3-drift.ps1` | the drift scenarios: provider code ahead of the contract, and contract ahead of the provider code |

**Why scripts instead of manual steps:** every result in the README can be reproduced with one command, which is also what the pipeline in Phase 7 will need.

---

## 8. The three layers of tests and why all three exist

| Layer | Tool | Where | What it proves | Example |
|---|---|---|---|---|
| **Internal (unit/component)** | xUnit | `well-registry-service.Tests` (13 tests) | which internal methods run, in which order, and that bad input never reaches the data | `Create` calls `NextId()` **before** `Add()`, exactly once |
| **Provider contract** | Specmatic `test` | `results/case1/`, `results/case2/provider-*` | the real service keeps the promise written in the spec | renaming `dailyCapacityBbl` fails 6 tests |
| **Consumer contract** | xUnit + Specmatic `stub` | `production-forecast-service.Tests` (6), `change-request-service.Tests` (5) | the consumer calls the provider correctly and handles every answer it relies on | the client maps the SHUT_IN example; a bad id is rejected by the stub |

**Why all three:** each catches what the others can't. In Phase 3, Specmatic caught **7 of 7** contract breaks that xUnit missed, and xUnit caught the one **business-logic** bug that kept the correct response shape, which Specmatic cannot see because it only checks shape and types. Consumer tests against a stub are the only layer that checks the **consumer's** side without the real provider running.

---

## 9. Where we are now

| Phase | Status | What it produced |
|---|---|---|
| 0 Environment | ✅ | tools checked, Specmatic 2.55.0 pinned (Docker), licence findings |
| 1 Structure | ✅ | 4 services, shared library, scripts, smoke test |
| 2 Contracts | ✅ | 4 specs, examples, `consumers.yaml`, tag `v1`; `/v2` and probes |
| 3 Case 1 | ✅ | provider tests 40% → 100% coverage, resiliency tests, xUnit, 9 break experiments, tag `v1.1` |
| 4 Case 2 | ✅ | provider tests for C1 and C2 pass; stubs under `/v2` (T4 solved); 11 consumer tests vs strict stubs pass; 6/6 breaks caught on both sides; Pact comparison |
| 5 Case 3 | ✅ | cross-app C3/C4 provider tests with mocked dependencies and consumer tests, specs from the git contract repo; compatibility gate fails a breaking change (exit 1); drift shown both ways |
| 6 Angular MFE | ✅ | Angular 21 page listing wells via a client **generated from the contract** (a contract break becomes a compile error); Playwright 4/4 against a strict stub through the dev-server proxy; MFE examples verified by the provider (contracts `v1.2`) |
| **7 Pipeline** | **next** | `run-all.ps1`, xUnit ContractTests projects, sample `azure-pipelines.yml` (incl. the Angular steps) |
| 8 Evaluation | planned | coverage, control points, scorecard, recommendation |

The README section "0. Master checklist" is the up-to-date, item-by-item status, with links to the evidence for every ticked item.
