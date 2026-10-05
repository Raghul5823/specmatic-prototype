# Demo C, first attempt: flaky gate (evidence reconstructed)

The original run folder (`results/pipeline/fail-mfe/`) was overwritten when demo C was rerun after the fix
(`run-all.ps1` clears its run folder at the start). The lines below were copied from that run's output as
captured during the session, unchanged except for formatting.

## Service pipeline output (run=fail-mfe, first attempt)
```
SERVICE PIPELINE  run=fail-mfe
  [1/7] Toolchain pinned                   PASSED (1s)
  [2/7] Build (.NET)                       PASSED (12s)
  [3/7] Unit tests                         PASSED (3s)
  [4/7] Provider contract tests            FAILED (173s)
Stage DeployDev: BLOCKED: BuildService failed at gate 'Provider contract tests'
Total 3.2 min
```

## Gate 4 log (per ContractTests project)
```
--- ProductionForecastService.ContractTests   Passed!  - Failed: 0, Passed: 1 (52 s)
--- WellRegistryService.ContractTests          Passed!  - Failed: 0, Passed: 1 (19 s)
--- ApprovalService.ContractTests              Passed!  - Failed: 0, Passed: 1 (17 s)
--- ChangeRequestService.ContractTests         Failed!  - Failed: 1, Passed: 0 (55 s)
```

## Specmatic (change-request-service): the one failing scenario
```
Scenario: POST /change-requests -> 201 with the request from the example 'CREATE_SMALL_CHOKE_CHANGE' has FAILED
  >> RESPONSE.STATUS
      R0002: HTTP status mismatch
      Specification expected status 201 but response contained status 502
Tests run: 7, Successes: 6, Failures: 1, WIP: 0, Errors: 0
```
Response returned by change-request-service:
```
502 Bad Gateway
Content-Type: application/problem+json
{ "title": "Upstream service error", "status": 502,
  "detail": "production-forecast-service: unreachable or timed out" }
```

## Dependency mock log (ct-deps-change-request)
```
- http://0.0.0.0:9102/v2 serving endpoints from specs:
- http://0.0.0.0:9202/v2 serving endpoints from specs:
GET /v2/forecasts/F-5001
X-Specmatic-Result: success
```
The mock **did** serve the forecast, but slower than the service's 5 s downstream timeout, and the
approval call never happened. The same test passed in the green run and in demo B, so this was timing
(the first call to a cold mock), not a contract problem.

## Fix (first round)
- `Downstream:TimeoutSeconds` configurable (default 5 s); ContractTests set 30 s for services under test with mocks.
- ContractTests warm up every mock (`GET /actuator/health`) before testing.
- With this, the demo C rerun stopped at the expected gate 6 (see `../fail-mfe/`).

The next full green run still failed at gate 4 for a related timing reason, so two more fixes followed
(Specmatic's request timeout larger than the service's downstream timeout, a real example request per mock as
warm-up, and a read-only-file clean-up bug). See README Phase 7, "What to notice" item 5, and `../stability/`.
