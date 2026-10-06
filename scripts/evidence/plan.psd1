# Run plan for scripts\run-evidence.ps1: what each report section proves, and every break demo with
# its expected outcome. Data only. To add a break demo, add a row here (and, for a new Source type,
# an evaluator in run-evidence.ps1).
#
# Break-demo expectation fields (omit a field = "don't care"):
#   ExpectSpecmatic  $true/$false  the Specmatic provider test failed (= caught the break)
#   ExpectXunit      $true/$false  the xUnit tests failed (unit tests, or consumer tests vs a strict stub)
#   ExpectExit       'zero'/'nonzero'  exit code of the check
#   ExpectText       text that must appear in the check's output (e.g. '502', 'TS2551')
#   ExpectMerge      'ALLOWED'/'BLOCKED'  contracts PR pipeline verdict
#   ExpectGate       the contracts PR gate that must have blocked the merge
#   Gate             $true when a failing check means a pipeline gate caught the break
#
# Report: the narrative at the top of the HTML report (purpose, approach, capabilities, known limits).
# Build-Report.ps1 reads it at render time, so wording can change without rerunning anything.
@{
    Report = @{
        Title    = 'Contract Testing Evidence'
        Subtitle = 'Specmatic (open-source edition) | .NET services | Angular micro-frontend | Azure DevOps pipeline gates'
        Purpose  = 'This report is produced by one command from the prototype. It demonstrates the contract-testing approach proposed for the real project: OpenAPI contracts in a central repository, Specmatic for provider contract tests and consumer stubs, a TypeScript client generated from the contract for the Angular micro-frontends, and pipeline gates that block merges and deployments on any contract failure.'
        Approach = @(
            @{ Stage = 'Central contract repository'; Items = @('OpenAPI 3 spec per service', 'Consumer-contributed examples', 'consumers.yaml: who relies on what', 'Semantic version tags') }
            @{ Stage = 'Contracts PR gate'; Items = @('Validate specs and every example', 'Bundle check for code generators', 'Backward compatibility vs main', 'Merge blocked on any failure') }
            @{ Stage = 'Service pipeline (BuildService)'; Items = @('Provider contract tests (Specmatic)', 'Consumer tests vs strict stubs', 'Generated TypeScript client + compile', 'UI tests vs a strict stub') }
            @{ Stage = 'Deployment'; Items = @('DeployDev depends on every gate', 'Evidence report before production approval') }
        )
        Capabilities = @(
            @{ Text = 'Contracts are valid, bundle for code generators and stay backward compatible'; Sections = @('contracts') }
            @{ Text = 'Every provider conforms to its contract, including every consumer-contributed example'; Sections = @('case1', 'case2', 'case3') }
            @{ Text = 'Consumers rely only on what the contract allows (strict stubs)'; Sections = @('case2', 'case3') }
            @{ Text = 'Angular micro-frontend: contract changes become compile errors; the UI is verified against a strict stub'; Sections = @('mfe') }
            @{ Text = 'The pipeline blocks deployment on any contract failure'; Sections = @('pipeline') }
            @{ Text = 'Deliberate breaks are caught by the layer designed to catch them'; Sections = @('breaks') }
            @{ Text = 'The run is reproducible and leaves the repositories unchanged'; Sections = @('env', 'hygiene') }
        )
        Limits = @(
            @{ Limit = 'Business-logic errors: correct shape, wrong data'; Cover = 'Unit and functional tests (contract tests check shape, not meaning)'; Demos = @('P3-7') }
            @{ Limit = 'New fields under an open schema (additionalProperties: true)'; Cover = 'Keep response schemas closed; review schema changes in the contracts PR'; Demos = @('P3-9') }
            @{ Limit = 'A consumer cannot see its provider''s drift'; Cover = 'The provider''s own contract test is a mandatory gate in its pipeline'; Demos = @('P5-D1b', 'P5-D1c') }
            @{ Limit = 'Real token validation, service-to-service auth and roles (RBAC)'; Cover = 'Integration and API automation tests with real tokens; contract tests prove the documented 401/403 responses'; Demos = @('P3-6', 'P4-3') }
            @{ Limit = 'Every breaking change fails the compatibility check (usage data is a commercial feature)'; Cover = 'Versioning policy: additive changes in MINOR versions, removals in a MAJOR version after deprecation'; Demos = @('A2', 'A5') }
            @{ Limit = 'No deployment matrix ("can I deploy?") in the open-source edition'; Cover = 'Pinned contract tags, the compatibility gate and a drift run against main'; Demos = @('A1', 'A5') }
            @{ Limit = 'Messaging and real-time channels (AsyncAPI is commercial; SignalR, SSE, WebSocket)'; Cover = 'Integration tests in the post-deploy test stage'; Demos = @() }
        )
    }

    Sections = @(
        @{ Id = 'env';       Title = 'Environment and versions'
           Proves = 'Which tool, contract and code versions produced this evidence, and that the machine was in a clean state.' }
        @{ Id = 'contracts'; Title = 'Contracts checks'
           Proves = 'Every spec and example in the central contracts repo is valid, bundles for code generators, and is backward compatible with main.' }
        @{ Id = 'case1';     Title = 'Case 1: provider contract (well-registry)'; Pairs = @('C1', 'C5')
           Proves = 'The real well-registry service satisfies its contract, including every consumer-contributed example and generated negative tests; its internal layers pass their unit tests.' }
        @{ Id = 'case2';     Title = 'Case 2: intra-app (C1, C2)'; Pairs = @('C1', 'C2')
           Proves = 'Within one app, each provider satisfies its consumer''s examples, and each consumer only uses what the contract allows (strict stubs).' }
        @{ Id = 'case3';     Title = 'Case 3: cross-app (C3, C4)'; Pairs = @('C3', 'C4')
           Proves = 'Across apps, in both directions, each provider passes its contract with the other app mocked, and each consumer works against a strict stub of the other app.' }
        @{ Id = 'mfe';       Title = 'Case 4: Angular MFE (C5)'; Pairs = @('C5')
           Proves = 'The frontend''s API client is generated from the contract, the app compiles against it, and the UI works against a strict stub.' }
        @{ Id = 'pipeline';  Title = 'Pipeline gates (service pipeline)'
           Proves = 'The BuildService gate sequence of the sample pipeline runs green end to end, so the DeployDev stage is allowed.' }
        @{ Id = 'breaks';    Title = 'Break demos (live, in a throwaway copy)'
           Proves = 'Deliberate breaks are caught by the expected layer, and the known gaps behave exactly as documented.' }
        @{ Id = 'hygiene';   Title = 'Clean-up and integrity'
           Proves = 'The run left nothing behind: services and containers stopped, both repos unchanged, the throwaway copy removed.' }
    )

    BreakDemos = @(
        # ---- Phase 3: Case 1, provider code breaks (scripts\case1-break-experiments.ps1) ----
        @{ Id = 'P3-1'; Phase = 3; Source = 'case1'; Key = '01-rename-field'; Gate = $true
           Change = 'Provider renames response field dailyCapacityBbl to dailyCapacity'; Layer = 'Provider contract test (Specmatic)'
           Expected = 'Specmatic fails'; ExpectSpecmatic = $true }
        @{ Id = 'P3-2'; Phase = 3; Source = 'case1'; Key = '02-change-type'; Gate = $true
           Change = 'Provider sends latitude as a string ("28.5")'; Layer = 'Provider contract test (Specmatic)'
           Expected = 'Specmatic fails'; ExpectSpecmatic = $true }
        @{ Id = 'P3-3'; Phase = 3; Source = 'case1'; Key = '03-remove-required-field'; Gate = $true
           Change = 'Provider omits required response field spudDate'; Layer = 'Provider contract test (Specmatic)'
           Expected = 'Specmatic fails'; ExpectSpecmatic = $true }
        @{ Id = 'P3-4'; Phase = 3; Source = 'case1'; Key = '04-change-success-status'; Gate = $true
           Change = 'POST /wells returns 200 instead of 201'; Layer = 'Provider contract test (Specmatic)'
           Expected = 'Specmatic fails'; ExpectSpecmatic = $true }
        @{ Id = 'P3-5'; Phase = 3; Source = 'case1'; Key = '05-non-problemdetails-error'; Gate = $true
           Change = '404 body is {message}, not ProblemDetails'; Layer = 'Provider contract test (Specmatic)'
           Expected = 'Specmatic fails'; ExpectSpecmatic = $true }
        @{ Id = 'P3-6'; Phase = 3; Source = 'case1'; Key = '06-drop-auth-check'; Gate = $true
           Change = 'Auth check removed: every request accepted'; Layer = 'Provider contract test (Specmatic, 401 examples)'
           Expected = 'Specmatic fails (401 examples)'; ExpectSpecmatic = $true }
        @{ Id = 'P3-7'; Phase = 3; Source = 'case1'; Key = '07-wrong-business-logic'; Gate = $true
           Change = 'Status filter inverted: right shape, wrong data'; Layer = 'Unit tests (xUnit); Specmatic cannot see it'
           Expected = 'Specmatic passes, xUnit fails'; ExpectSpecmatic = $false; ExpectXunit = $true }
        @{ Id = 'P3-8'; Phase = 3; Source = 'case1'; Key = '08-new-field-no-spec-update'; Gate = $true
           Change = 'Provider adds response field "region" not in the spec (closed schema)'; Layer = 'Provider contract test (Specmatic)'
           Expected = 'Specmatic fails'; ExpectSpecmatic = $true }
        @{ Id = 'P3-9'; Phase = 3; Source = 'case1'; Key = '09-new-field-additionalProperties-true'; Gate = $true
           Change = 'Same new field, but the spec allows additional properties'; Layer = 'Known gap (open schema)'
           Expected = 'Not caught by any layer (documented gap)'; ExpectSpecmatic = $false; ExpectXunit = $false }

        # ---- Phase 4: Case 2, both sides of C1 and C2 (scripts\case2-break-experiments.ps1) ----
        @{ Id = 'P4-1'; Phase = 4; Source = 'case2'; Key = '01-consumer-wrong-path'; Gate = $true
           Change = 'C1 consumer calls /v2/well/{id} instead of /v2/wells/{id}'; Layer = 'Consumer test vs strict stub'
           Expected = 'Consumer tests fail'; ExpectXunit = $true }
        @{ Id = 'P4-2'; Phase = 4; Source = 'case2'; Key = '02-consumer-expects-extra-field'; Gate = $true
           Change = 'C1 consumer relies on a field the contract does not have'; Layer = 'Consumer test vs strict stub'
           Expected = 'Consumer tests fail'; ExpectXunit = $true }
        @{ Id = 'P4-3'; Phase = 4; Source = 'case2'; Key = '03-consumer-wrong-auth-scheme'; Gate = $true
           Change = 'C1 consumer sends "Token" instead of "Bearer"'; Layer = 'Consumer test (recording handler, T5)'
           Expected = 'Consumer tests fail'; ExpectXunit = $true }
        @{ Id = 'P4-4'; Phase = 4; Source = 'case2'; Key = '04-consumer-renames-request-field'; Gate = $true
           Change = 'C2 consumer sends capacityDelta instead of required capacityDeltaBbl'; Layer = 'Consumer test vs strict stub'
           Expected = 'Consumer tests fail'; ExpectXunit = $true }
        @{ Id = 'P4-5'; Phase = 4; Source = 'case2'; Key = '05-provider-renames-decision'; Gate = $true
           Change = 'C2 provider renames response field decision to outcome'; Layer = 'Provider contract test (Specmatic)'
           Expected = 'Specmatic fails'; ExpectSpecmatic = $true }
        @{ Id = 'P4-6'; Phase = 4; Source = 'case2'; Key = '06-provider-changes-status'; Gate = $true
           Change = 'C2 provider returns 200 instead of 201 for POST /approvals'; Layer = 'Provider contract test (Specmatic)'
           Expected = 'Specmatic fails'; ExpectSpecmatic = $true }

        # ---- Phase 5: Case 3 drift, both directions (scripts\case3-drift.ps1) ----
        @{ Id = 'P5-D1a'; Phase = 5; Source = 'drift'; Key = 'd1a_provider_test'; Gate = $true
           Change = 'Provider code renames wellId to well_id, contract unchanged'; Layer = 'Provider contract test (deps mocked)'
           Expected = 'Provider test fails (drift caught)'; ExpectExit = 'nonzero' }
        @{ Id = 'P5-D1b'; Phase = 5; Source = 'drift'; Key = 'd1b_consumer_stub_tests'; Gate = $true
           Change = 'Same provider drift'; Layer = 'Consumer test vs strict stub'
           Expected = 'Consumer tests pass: the consumer cannot see provider drift'; ExpectExit = 'zero' }
        @{ Id = 'P5-D1c'; Phase = 5; Source = 'drift'; Key = 'd1c_real_integration'; Gate = $false
           Change = 'Same provider drift, real services end to end'; Layer = 'Runtime (no gate)'
           Expected = '502 at runtime: the cost of skipping the provider gate'; ExpectText = '502' }
        @{ Id = 'P5-D2'; Phase = 5; Source = 'drift'; Key = 'd2_provider_vs_changed_contract'; Gate = $true
           Change = 'Contract renames wellId to wellID, provider code unchanged'; Layer = 'Provider contract test vs changed contract'
           Expected = 'Provider test fails'; ExpectExit = 'nonzero' }

        # ---- Phase 6: MFE, contract change becomes a compile error (scripts\mfe-compile-break.ps1) ----
        @{ Id = 'P6-1'; Phase = 6; Source = 'mfe-compile'; Key = 'compile-break'; Gate = $true
           Change = 'Spec renames dailyCapacityBbl to dailyCapacity; client regenerated'; Layer = 'MFE compile (generated client)'
           Expected = 'Build fails; passes again with the real contract'; ExpectExit = 'nonzero' }

        # ---- Phase 7: contracts PR pipeline (scripts\pipeline-failure-demos.ps1 -Only A) ----
        @{ Id = 'A1'; Phase = 7; Source = 'pr'; Key = 'A1-compatible-optional-field'; Gate = $true
           Change = 'Add optional response field Forecast.notes'; Layer = 'Contracts PR pipeline'
           Expected = 'MERGE ALLOWED (additive change)'; ExpectMerge = 'ALLOWED' }
        @{ Id = 'A2'; Phase = 7; Source = 'pr'; Key = 'A2-deprecate-endpoint'; Gate = $true
           Change = 'Mark GET /wells as deprecated'; Layer = 'Contracts PR pipeline'
           Expected = 'MERGE ALLOWED (deprecation is not breaking)'; ExpectMerge = 'ALLOWED' }
        @{ Id = 'A3'; Phase = 7; Source = 'pr'; Key = 'A3-breaking-required-request-field'; Gate = $true
           Change = 'New required request field operator, examples not updated'; Layer = 'Contracts PR pipeline'
           Expected = 'BLOCKED at examples validation'; ExpectMerge = 'BLOCKED'; ExpectGate = 'Validate specs + examples' }
        @{ Id = 'A4'; Phase = 7; Source = 'pr'; Key = 'A4-breaking-rename-response-field'; Gate = $true
           Change = 'Rename required response field Forecast.wellId to wellID'; Layer = 'Contracts PR pipeline'
           Expected = 'BLOCKED at examples validation'; ExpectMerge = 'BLOCKED'; ExpectGate = 'Validate specs + examples' }
        @{ Id = 'A5'; Phase = 7; Source = 'pr'; Key = 'A5-breaking-examples-updated'; Gate = $true
           Change = 'Same as A3, with every example updated'; Layer = 'Contracts PR pipeline'
           Expected = 'BLOCKED at backward compatibility'; ExpectMerge = 'BLOCKED'; ExpectGate = 'Backward compatibility vs main' }

        # ---- Phase 7: service pipeline gates, only the relevant check ----
        @{ Id = 'B'; Phase = 7; Source = 'svc-provider'; Key = 'B'; Gate = $true
           Change = 'well-registry code renames dailyCapacityBbl to dailyCapacity (contract unchanged)'; Layer = 'Gate 4: provider ContractTests'
           Expected = 'ContractTests fail'; ExpectExit = 'nonzero' }
        @{ Id = 'C'; Phase = 7; Source = 'svc-mfe'; Key = 'C'; Gate = $true
           Change = 'MFE code reads well.dailyCapacity, a field the contract does not have'; Layer = 'Gate 6: MFE build'
           Expected = 'Build fails with TS2551'; ExpectExit = 'nonzero'; ExpectText = 'TS2551' }
    )
}
