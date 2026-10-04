| Side | Change | Expected | Caught? | Evidence |
|---|---|---|---|---|
| consumer (C1) | Consumer calls GET /v2/well/{id} instead of /v2/wells/{id} | caught by stub | **YES**: consumer tests vs strict stub failed | [01-consumer-wrong-path](results/case2/break/01-consumer-wrong-path/) |
| consumer (C1) | Consumer starts relying on a field the contract does not have (WellSummary.Operator) | caught (field not in contract) | **YES**: consumer tests vs strict stub failed | [02-consumer-expects-extra-field](results/case2/break/02-consumer-expects-extra-field/) |
| consumer (C1) | Consumer sends "Authorization: Token ..." instead of "Bearer ..." | only the token-recording test (T5) | **YES**: consumer tests vs strict stub failed | [03-consumer-wrong-auth-scheme](results/case2/break/03-consumer-wrong-auth-scheme/) |
| consumer (C2) | Consumer sends capacityDelta instead of required capacityDeltaBbl | caught by stub | **YES**: consumer tests vs strict stub failed | [04-consumer-renames-request-field](results/case2/break/04-consumer-renames-request-field/) |
| provider (C2) | Provider renames response field decision -> outcome | caught by provider test | **YES**: provider contract test (5/6 failed) | [05-provider-renames-decision](results/case2/break/05-provider-renames-decision/) |
| provider (C2) | Provider returns 200 instead of 201 for POST /approvals | caught by provider test | **YES**: provider contract test (4/6 failed) | [06-provider-changes-status](results/case2/break/06-provider-changes-status/) |
