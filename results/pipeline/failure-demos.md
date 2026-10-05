| Demo | Pipeline | Change | Expected | Stopped at gate | Outcome |
|---|---|---|---|---|---|
| A1-compatible-optional-field | contracts PR | Add optional response field Forecast.notes | MERGE ALLOWED | - | MERGE ALLOWED |
| A2-deprecate-endpoint | contracts PR | Mark GET /wells (listWells) as deprecated | MERGE ALLOWED | - | MERGE ALLOWED |
| A3-breaking-required-request-field | contracts PR | Make new request field CreateWellRequest.operator REQUIRED | MERGE BLOCKED | Validate specs + examples | MERGE BLOCKED by gate 'Validate specs + examples' |
| A4-breaking-rename-response-field | contracts PR | Rename required response field Forecast.wellId -> wellID | MERGE BLOCKED | Validate specs + examples | MERGE BLOCKED by gate 'Validate specs + examples' |
| A5-breaking-examples-updated | contracts PR | Make CreateWellRequest.operator REQUIRED and update every example (careful but breaking PR) | MERGE BLOCKED | Backward compatibility vs main | MERGE BLOCKED by gate 'Backward compatibility vs main' |
| fail-provider | service | well-registry code renames response field dailyCapacityBbl -> dailyCapacity (contract unchanged) | stop at Provider contract tests | Provider contract tests | DeployDev BLOCKED: BuildService failed at gate 'Provider contract tests' |
| fail-mfe | service | MFE code reads well.dailyCapacity, a field the contract does not have | stop at MFE: client + build | MFE: client + build | DeployDev BLOCKED: BuildService failed at gate 'MFE: client + build' |
