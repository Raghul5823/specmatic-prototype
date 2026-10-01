| Change | Expected | Specmatic caught? | xUnit caught? | Evidence |
|---|---|---|---|---|
| Rename response field dailyCapacityBbl -> dailyCapacity | caught | **YES** (6/15 failed) | no | [results/case1/break/01-rename-field/](results/case1/break/01-rename-field/) |
| Change field type: latitude number -> string ("28.5") | caught | **YES** (6/15 failed) | no | [results/case1/break/02-change-type/](results/case1/break/02-change-type/) |
| Remove required response field spudDate | caught | **YES** (6/15 failed) | no | [results/case1/break/03-remove-required-field/](results/case1/break/03-remove-required-field/) |
| Change success status of POST /wells: 201 -> 200 | caught | **YES** (1/15 failed) | no | [results/case1/break/04-change-success-status/](results/case1/break/04-change-success-status/) |
| 404 body is {message} (application/json), not ProblemDetails | caught | **YES** (2/15 failed) | no | [results/case1/break/05-non-problemdetails-error/](results/case1/break/05-non-problemdetails-error/) |
| Drop the auth check (every request accepted) | caught via 401 examples | **YES** (4/15 failed) | **YES** | [results/case1/break/06-drop-auth-check/](results/case1/break/06-drop-auth-check/) |
| Wrong logic, correct shape: status filter inverted (SHUT_IN returns the ACTIVE wells) | NOT caught by Specmatic | no (15 passed) | **YES** | [results/case1/break/07-wrong-business-logic/](results/case1/break/07-wrong-business-logic/) |
| Provider adds NEW response field "region" without a spec update | caught (closed schema) | **YES** (6/15 failed) | no | [results/case1/break/08-new-field-no-spec-update/](results/case1/break/08-new-field-no-spec-update/) |
| Same new field, but spec Well schema has additionalProperties: true | not caught (open schema) | no (15 passed) | no | [results/case1/break/09-new-field-additionalProperties-true/](results/case1/break/09-new-field-additionalProperties-true/) |
