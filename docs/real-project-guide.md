# Contract testing in a real project

A guide for teams moving from this prototype to contract testing in a real system with .NET services, Angular micro-frontends (MFEs), Azure DevOps pipelines and OAuth2. It is based on what the prototype showed in Phases 0–7; the evidence is linked from the [README](../README.md).

**Legend:**
- ✅ = proven in this prototype.
- ⚠️ = recommended but **not** tested here. Verify it in your own setup before you rely on it.

Contents
1. [System design of the prototype](#1-system-design-of-the-prototype)
2. [System patterns used](#2-system-patterns-used)
3. [Recommendations for a real project](#3-recommendations-for-a-real-project)
4. [Rollout plan](#4-rollout-plan)
5. [If you only do five things](#5-if-you-only-do-five-things)

---

## 1. System design of the prototype

### Services and dependencies
```
Angular MFE (well-mfe)   ──► well-registry-service          App A, frontend to backend
production-forecast      ──► well-registry                   App A, same app
production-forecast      ──► change-request                  cross-app (A to B)
change-request           ──► approval                        App B, same app
change-request           ──► production-forecast             cross-app (B to A)
```

### Two repositories
| Repository | Holds |
|---|---|
| **Contracts** (separate git repo, cloned at `contracts/`) | OpenAPI specs (`specs/<app>/<service>.yaml`), shared schemas (`common/common.yaml`), consumer examples (`specs/<app>/<service>_examples/`), the consumer registry (`consumers.yaml`), release tags `v1`, `v1.1`, `v1.2` |
| **Prototype** (this repo) | Services, tests, Specmatic configs (`specmatic/`), scripts, sample pipelines (`pipelines/`), evidence (`results/`) |

### Test layers
| Layer | How | What it proves | Service pipeline gate |
|---|---|---|---|
| Unit | xUnit (`*.Tests`) | The service's own logic | 3 |
| Provider contract | Specmatic `test` inside an xUnit `*.ContractTests` project; the service's dependencies are Specmatic mocks | The service matches its spec, including **every consumer's example** | 4 |
| Consumer contract | The consumer's real typed `HttpClient` against a **strict** Specmatic stub (`*ClientStubTests.cs`) | The consumer only sends and reads what the spec allows | 5 |
| MFE compile | TypeScript client generated from the spec | The frontend code still matches the spec | 6 |
| MFE end-to-end | Playwright against a strict stub (`mfe/well-mfe/e2e/`) | The UI works with data shaped like the contract | 7 |
| Contract change | `examples validate` + backward-compatibility check against `main` | A spec PR can't silently break consumers | contracts PR pipeline |

---

## 2. System patterns used

| # | Pattern | Where it is in the prototype | Why it matters |
|---|---|---|---|
| 1 | **Contract-first** (spec-first) | `contracts/specs/**`, written in Phase 2 before the service code | The spec is the agreement. It can be reviewed before any code exists, and teams can build against it in parallel. |
| 2 | **Central contract repository** | The separate `contracts/` git repo, mounted read-only into Specmatic (`/work/contracts:ro`) | One reviewable source of truth. Consumers see provider changes, and nobody keeps a private copy that drifts. |
| 3 | **Semantic versioning of contracts** | Tags `v1`, `v1.1`, `v1.2` in the contracts repo; `ref: refs/tags/v1.2` in `pipelines/azure-pipelines.yml` | Release builds are reproducible. MINOR = additive, MAJOR = breaking. |
| 4 | **Consumer-contributed examples** | `specs/<app>/<service>_examples/<consumer>__<scenario>.json`, e.g. `production-forecast__get_well_W-001_active.json` | The provider is tested against what its consumers actually rely on, and the file name shows who owns each example. This gives consumer-driven contracts without a broker. |
| 5 | **Consumer registry** | `contracts/consumers.yaml` (interactions C1–C5: operation, responses and fields used, example files) | The free edition has no usage data, so this file is the only record of who a change affects. Specmatic doesn't read it; people and scripts do. |
| 6 | **Service virtualisation** | Specmatic mocks and stubs built from the same specs: `specmatic/*.mock.yaml`, `scripts/stub.ps1`, `scripts/deps.ps1`, `Specmatic.StartDependencyMocks` in `shared/Prototype.ContractTesting/` | Each service is tested on its own, without its real dependencies. The mock can't drift from the contract because it *is* the contract. |
| 7 | **Strict stubs** | `--strict` in `scripts/stub.ps1`; gate 5 of `scripts/run-all.ps1` | A request the contract doesn't describe fails, instead of getting a made-up answer. So a consumer can't come to rely on behaviour nobody agreed to. |
| 8 | **Client code generation** | `generate:api` in `mfe/well-mfe/package.json` (runs before every build and start); `scripts/bundle-spec.mjs`; output `src/app/api/` (never committed) | A contract change becomes a **compile error** in the frontend (demo C: TS2551), not a runtime bug. |
| 9 | **Backward-compatibility gate** | `scripts/compat-check.ps1`; gate 3 of `scripts/contracts-pr-check.ps1` | A breaking spec change can't be merged by accident (demo A5). |
| 10 | **Expand–contract deprecation** | `deprecated: true` passes every gate (demo A2); the README note "Deprecating an endpoint" | Add the new element, mark the old one deprecated, move the consumers, and remove the old one only in the next MAJOR version. A breaking change becomes a planned migration. |
| 11 | **Shift-left gates** | `examples validate` in the contracts PR (A3 and A4 stopped at gate 1), contract tests in the build stage, the MFE compile | Each break is caught at the earliest and cheapest point, and by the team that caused it. |
| 12 | **Two-pipeline governance** | `pipelines/contracts-pr-pipeline.yml` guards merges; `pipelines/azure-pipelines.yml` guards deploys | Both contract changes and code changes are gated, and neither path can bypass the other. |
| 13 | **Layered test pyramid** | Unit (`*.Tests`) → provider (`*.ContractTests`) → consumer against stubs (`*ClientStubTests.cs`) → MFE end-to-end (`mfe/well-mfe/e2e/`) | Each layer proves one thing quickly, so only a few slow end-to-end tests are needed. |
| 14 | **ProblemDetails errors** | `AddProblemDetails` and `UseStatusCodePages` in `shared/Prototype.ServiceDefaults/ServiceDefaults.cs`; error schemas in `contracts/common/common.yaml` | Every error has one documented shape (RFC 9457), so error responses are part of the contract and are tested too. |
| 15 | **URI versioning** | `servers: - url: /v2` in each spec; mock `baseUrl …/v2` | A MAJOR version gets a new base path, so old and new versions can run side by side during a migration. |
| 16 | **Health probes outside contracts** | `/liveness` and `/readiness` in `ServiceDefaults.cs`: no auth, not under `/v2`, not in the specs | Probes serve the orchestrator, not consumers, so they don't need versioning. The ContractTests wait for `/readiness` before testing. |
| 17 | **Shared service defaults** | `shared/Prototype.ServiceDefaults/` (JSON settings, ProblemDetails, auth middleware, probes, downstream clients) | Every service behaves the same way, so one set of contract rules fits all of them. |
| 18 | **Fail fast with 502 on a dependency failure** | `Downstream.SendAsync` / `Downstream.Problem` and `Downstream:TimeoutSeconds` (default 5 s) in `ServiceDefaults.cs` | A slow or broken dependency gives a quick, documented 502 instead of a hang. The timeout is a setting that tests can raise. |
| 19 | **Tolerant reader / strict provider** | `Json.Configure` in `ServiceDefaults.cs` ignores unknown fields (the System.Text.Json default) but rejects wrong types, nulls and missing required fields; Specmatic checks provider responses against the spec | Adding an optional field never breaks a consumer (demo A1), yet a consumer still fails loudly when a field it uses changes. |
| 20 | **Recording handler (spy)** | `RecordingHandler.cs` in `production-forecast-service.Tests/` and `change-request-service.Tests/` | The stub only checks that a `Bearer …` header is present. The spy proves which token the real client sends (finding T5). |
| 21 | **Same-origin dev proxy** | `mfe/well-mfe/proxy.conf.json` (`/v2` → the stub on port 9101) | The browser only talks to its own origin, so local runs and Playwright need no CORS setup, and the same relative URLs work behind a gateway. |
| 22 | **Version pinning** | `global.json` (.NET SDK), `mfe/well-mfe/.nvmrc` (Node), `.npmrc` (`save-exact`), exact package versions, `nuget.config`, Specmatic image tag `2.55.0` (`scripts/common.ps1`, the YAML) | The same results on every machine and agent, and upgrades become deliberate PRs. Gate 1 of the service pipeline fails on a mismatch. |
| 23 | **Evidence-based results** | `results/<phase or run>/` (console output, JUnit, HTML reports, `summary.json`), linked from the README | Every claim can be checked. Personal data is removed before anything is published. |
| 24 | **Dependency switched by configuration only** | `AddDownstreamClient` in `ServiceDefaults.cs`: the base URL (including `/v2/`) comes from config, and clients use relative paths | Pointing a service at a stub, a mock or the real dependency is a configuration change, not a code change. |
| 25 | **Shared schemas via `$ref`, plus bundling** | `contracts/common/common.yaml`; `scripts/bundle-spec.mjs` for generators that can't follow external `$ref`s | Common types are defined once, and code generators still work. |

---

## 3. Recommendations for a real project

### 3.1 Ownership: QA owns the standards, not every change
The aim is that **QA does not become a bottleneck**. Developers own the specs, consumers own their examples, and QA owns the rules and checks that keep the system healthy.

| Role | Owns | Approves |
|---|---|---|
| **Provider developers** | The spec of their service, the provider ContractTests, fixing provider breaks, seed data for examples | Spec PRs for their service |
| **Consumer developers** | Their examples (`<consumer>__*.json`), their consumer tests against stubs, their entries in `consumers.yaml` | Spec PRs of the providers they use |
| **QA (standards)** | Spec linting rules, the versioning and deprecation policy, contract test templates, review of `consumers.yaml` changes, release quality evidence | Changes to the rules (not every spec PR) |
| **Platform / DevOps** | Pipeline templates, build agents, the Specmatic image in the internal registry, tool upgrades | Template changes |
| **Architecture** | API guidelines, decisions on MAJOR versions and new cross-app dependencies | MAJOR versions |

- ⚠️ Enforce ownership with required reviewers per path in the contracts repo (CODEOWNERS or branch policies). The provider and every consumer listed in `consumers.yaml` should review a spec change.
- ✅ Automate the mechanical checks (validate, bundle, compatibility) in the PR. ⚠️ Add linting as well. Reviewers then judge intent, not syntax.

### 3.2 Contract version strategy: pinned tags plus a drift run
Use **two kinds of run**. Each one covers what the other can't.

| Run | Contract version | Trigger | Blocks | Catches |
|---|---|---|---|---|
| **Release build** ✅ | A **pinned tag** (e.g. `v1.2`) | Every PR and commit in the service repo | Merge and deploy | Regressions in the service against the agreed version |
| **Drift run** ⚠️ | Contracts **`main`** | A change in the contracts repo (repository-resource trigger) or **nightly** | Nothing directly; it notifies the provider team | **New consumer examples** the provider doesn't satisfy yet, spec changes not implemented yet, drift between spec and code. All caught **the same day**. |

- With pinning alone, builds are stable but new consumer examples stay hidden until the next tag bump. With `main` alone, a team's build can change underneath them.
- Rule: **cut a new contract tag only when every provider's drift run is green.**
- Bump the pinned tag in a service repo through a normal PR, so the bump is visible and tested.
- ⚠️ In Azure Pipelines, repository-resource triggers work for Azure Repos Git repositories. For other hosts, use a scheduled run.

### 3.3 Spec and example quality
- ✅ **Examples are the first line of defence.** In the contracts PR demos, `examples validate` stopped two of the three breaking changes (A3, A4) before the compatibility check ran. Require an example for every success and every error response.
- ⚠️ Add a spec linter (for example Spectral) with house rules: naming, ProblemDetails for every error, security on every operation, pagination. QA owns the ruleset.
- ✅ Consumers read tolerantly: they ignore unknown fields but fail on wrong types or on missing fields they use (pattern 19).
- Use only synthetic example data. Use stable IDs (`W-001`) that match the seed data (see 3.5).
- ✅ Keep example file names short: Windows has a 260-character path limit (Phase 5).

### 3.4 Test strategy
- **Contract tests check the interface, not the business logic.** Keep unit and functional tests, and add a **thin** post-deploy smoke and API automation suite. Contract tests replace most integration end-to-end tests, but not all of them.
- ✅ Use strict stubs for consumer tests, and generate frontend clients from the spec instead of writing DTOs by hand.
- ✅ Run resiliency tests (generated negative tests, free edition) **nightly**, with a cap on combinations. Uncapped, they are too slow and too large for a PR gate (Phase 3).
- ✅ **Timeout budget for tests against mocks (Phase 7):** the outer timeout must be larger than the inner one (Specmatic request timeout > the service's downstream timeout). Add a readiness check and warm up each mock with one real example request. Without these, gate 4 failed at random.

### 3.5 Test data for database-backed services
In the prototype the repositories are in memory, seeded with fixed data that matches the examples (e.g. `WellRepository.cs` seeds W-001 to W-003). Real services read from a database, and there are two ways to run their ContractTests:

| | A: ContractTest mode with in-memory repositories | B: Testcontainers for the database |
|---|---|---|
| **How** | The service starts in a `ContractTest` environment. Dependency injection swaps the repository interfaces for in-memory versions seeded with the example data. | The ContractTests project starts a real database in a container (Testcontainers for .NET), runs the migrations and a seed script, and points the service at it. |
| **Proves** | The HTTP contract: routes, status codes, shapes, validation, error mapping | All of A, plus the data layer where it shapes responses (mapping, nullability, lengths, migrations) |
| **Speed** | Fast | Slower: a container start and migrations on every run |
| **Needs** | Repository interfaces in the service; in-memory versions kept in step with the real ones | Docker on the agent; the database image in the internal registry (and its licence, if commercial) |
| **Risk** | The in-memory version can behave differently from the real database (constraints, case sensitivity, transactions) | More moving parts, so more sources of flaky failures |
| **Fits** | Most services; **start here** | Services where the data layer shapes the response (computed columns, views, stored procedures) |

Status: A ✅ (in its simplest form). B ⚠️ (not tested).

**Seeding is required in both options, even if database validation is out of QA scope.** Every example has preconditions. An example for `GET /wells/W-001` needs W-001 to exist in the data.
- Keep the seed data in the service repo next to the ContractTests, keyed by the IDs that the examples use.
- When a consumer adds an example with a new ID, the provider team adds the seed row in the same change.
- When a provider test fails right after a new consumer example arrives, the cause is often missing seed data, not a code bug.
- Never point ContractTests at a shared environment's database.

### 3.6 Auth and security
- **Prototype:** every service accepts one fixed test token (`TestBearerTokenMiddleware`), and the Specmatic stub only checks that the header has the `Bearer …` format (finding T5). The recording handler (pattern 20) shows which token the consumer actually sends.
- **Real project ⚠️:**
  - Keep the real JWT bearer validation for normal runs.
  - Register a **test authentication handler only in ContractTest mode**. It accepts the test token and creates a user with the claims and roles that the examples need.
  - Make sure it can never be switched on in a deployed environment: register it only for the `ContractTest` environment, and never deploy that environment's settings.
- **What contract tests prove:** the security scheme is declared, and 401/403 responses are documented and returned in the agreed shape.
- **What they don't prove** (cover these with **integration and API automation tests** that use real tokens from a test identity provider):
  - real token validation: issuer, audience, signature, expiry;
  - **service-to-service auth** (client credentials, managed identity);
  - **RBAC**, i.e. who is allowed to do what. Test the role matrix in API automation.
- Never put real tokens in specs or examples. Pipeline secrets belong in secret variables or a key vault.

### 3.7 Frontends in a monorepo (for example Nx) ⚠️
The prototype used a single Angular app. In a monorepo with several MFEs:
- **One generated client library per service API**, e.g. `libs/api/well-registry-client`. It holds the generated code, built from the bundled spec of the pinned contract tag, and every MFE that calls that API imports it. Don't let each MFE generate its own copy.
- **Make client generation and stub tests build targets:**
  - a `generate-api` target on the client library (bundle the spec, then generate);
  - the MFE's `build` target depends on it;
  - a `test-contract` target runs the stub tests (Playwright or component tests against a strict stub).
- **Run only affected projects** (e.g. `nx affected -t build test-contract`). Make the bundled spec, or the file that pins the contract version, an **input** of the client library. Bumping the contract tag then marks every consumer of that API as affected, and nothing else.
- ✅ Never edit generated code by hand. Either regenerate it on every build without committing it (as the prototype does), or commit it with a CI check that regenerating leaves no diff.
- ✅ Some generators don't resolve external `$ref`s (ng-openapi-gen 1.1.0 doesn't), so bundle first.

### 3.8 Stage mapping to a typical enterprise pipeline template
```
Build stage ──► Deploy DEV ──► post-deploy test hook ──► higher environments ──► release evidence ──► manual PROD approval ──► Deploy PROD
 compile, unit,               smoke + API automation     (same hooks)            collected             (a person decides)       smoke
 ALL contract gates
```

| Stage | What runs | Role in contract testing |
|---|---|---|
| **Build (CI)** | Build, unit tests, provider ContractTests, consumer tests against strict stubs, MFE generate + build + Playwright against a stub; publish JUnit and HTML reports | ✅ **All contract gates run here, before the first environment.** A failure stops everything after it. |
| **Deploy DEV + post-deploy test hook** | Smoke tests and API automation with real auth and real dependencies | ⚠️ Proves what contract tests can't: real tokens, RBAC, real integration, messaging (see 3.10) |
| **Higher environments** | The same hooks, with more realistic data | – |
| **Release quality evidence** | Contract test results, compatibility-check result, the contract tag used, Specmatic API coverage, smoke and API automation results | ⚠️ Attached to the release, so the approver decides on evidence |
| **Manual production approval** | A person reviews the evidence | Approval based on evidence, not trust |

- ✅ The contracts PR pipeline is separate. It guards merges into the contracts repo and never deploys.
- Pin versions on the agent; on Linux agents, bind services to `0.0.0.0` or run Specmatic with `--network host` (⚠️ not verified); run each service's gates as parallel jobs (each uses its own ports); pull the Specmatic image from an internal registry.
- ✅ **Pin the shell as well as the tool versions.** Run PowerShell steps with **PowerShell 7 explicitly** (`PowerShell@2` with `pwsh: true`, or a `pwsh:` step), or use `bash:`. Never rely on Windows PowerShell 5.1's quoting: it strips the inner double quotes from arguments passed to native programs. This prototype hit it in Phase 8a: a JSON body passed to `curl.exe` arrived as invalid JSON, so a demo got 400 instead of 502. A plain `script:` step runs **cmd.exe on Windows agents and bash on Linux agents**, so the same step can behave differently. Prefer `bash:` or `pwsh:` to make the shell explicit.
- ✅ **Pass JSON to tools through files, not inline command-line arguments**, e.g. `curl --data-binary @body.json` or a `--config` file. No shell's quoting rules can then change the content.
- ✅ **Run local tests in the same shell as the pipeline agent.** A different shell is a different environment. Here, Phases 3–7 ran on PowerShell 7.6, and the first full run on 5.1 found a defect that 7.6 had hidden.

### 3.9 Making the gates mandatory: the exit criterion
1. **Start in shadow mode.** The gates run and report, but don't block yet.
2. **Exit criterion: N consecutive green runs (for example 10) on the real build agent.** That means the same agent pool, the real network and the full pipeline load. Every failure in that window must be a real, explained contract break; **any flaky failure resets the count.** A failure caused by the test harness itself (a script, the shell, the environment) also resets the count. Run 2 of Phase 8a is an example: a shell-quoting defect, deterministic rather than flaky, but not a contract break.
3. Then make the gates required: build validation on the branch policy, and `dependsOn` for deploys.
4. Keep measuring the flaky-failure rate. Agree a fix-or-quarantine rule, because **a gate that fails at random will be ignored**.

Why: in this prototype, gate 4 needed three rounds of fixes before it was stable on a laptop (README Phase 7, item 5). A real agent will have its own timing.

### 3.10 Not covered by contract tests
| Area | Why it is not covered | Cover it with |
|---|---|---|
| **Real-time channels** (SignalR, SSE, WebSocket) | Not OpenAPI request/response; not tested in this prototype | Integration tests: a test client connects and asserts the messages it receives |
| **Messaging** (queues, topics, events) | **AsyncAPI support is a commercial Specmatic feature**; this evaluation covers the open-source edition and OpenAPI only. Check the current Specmatic docs, as editions change. | Integration tests against the broker (or an emulator) in the post-deploy hook. ⚠️ Also validate message payloads against a shared schema in the producer's and consumer's unit tests. |
| Real auth, service-to-service auth, RBAC | See 3.6 | Integration and API automation tests |
| Business rules | Contracts check shape, not meaning | Unit and functional tests |
| Performance, security scanning, UI behaviour | Outside what a contract describes | Dedicated test types |

### 3.11 Tool and licence risks (open-source edition)
- ✅ The backward-compatibility check fails on **every** breaking change: without usage data (a commercial feature), it can't tell an unused endpoint from a used one. Plan removals as MAJOR versions (pattern 10).
- ✅ CTRF reports and template values are commercial features. JUnit and HTML reports are free and are enough for a pipeline.
- Track the **bundled open-source licence expiry: 14 Dec 2027** (tracked item T2 in the README), and the Docker Desktop licence for developer machines. Agents without Docker can use the JAR route (README Phase 7).
- ⚠️ Scan the Specmatic image (with your security team's approval) and mirror it in an internal registry.
- Upgrade Specmatic deliberately: change the pinned tag in one PR, run the full suite, then roll it out.

### 3.12 Architecture notes
- ✅ production-forecast and change-request call each other across apps. Contract testing copes (each side mocks the other), but their releases become coupled: a breaking change on either side needs a coordinated release. ⚠️ Consider making one direction an event or a read model.
- Cross-app calls should go only through documented contracts in the central repo, never through a shared database.

---

## 4. Rollout plan
1. Start with **one pair**: a simple provider and its MFE (here: well-registry and well-mfe).
2. Add one intra-app link, then one cross-app link.
3. Run the gates in shadow mode until the exit criterion (3.9) is met, then make them mandatory.
4. Add the drift run (3.2) and the post-deploy API automation (3.8).
5. Measure: the percentage of endpoints with a contract, Specmatic API coverage, the flaky-failure rate, and interface defects that still reached test or production.

## 5. If you only do five things
1. A **central contracts repo** with branch protection and required reviewers (provider plus consumers).
2. **Consumers own their examples**, and providers keep seed data for them.
3. **Pinned contract tags** with semantic versioning, plus a **drift run** against `main`.
4. **Contract gates in the build stage**, before merge and before the first environment, made mandatory only after N green runs on the real agent.
5. A clear split: **contract tests prove the interface**; integration and API automation prove auth, RBAC, real-time and messaging.
