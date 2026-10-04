import { expect, test } from '@playwright/test';

/**
 * Consumer contract tests of the MFE (interaction C5: well-mfe -> well-registry GET /v2/wells),
 * run in a real browser against a STRICT Specmatic stub generated from the contract.
 */
test.describe('well-mfe against the Specmatic stub', () => {
  test('lists the wells from the consumer example and sends the bearer token', async ({ page }) => {
    const apiRequest = page.waitForRequest((r) => r.url().includes('/v2/wells'));
    await page.goto('/');

    const request = await apiRequest;
    // Same origin (via the dev-server proxy), so the browser needs no CORS.
    expect(new URL(request.url()).origin).toBe('http://localhost:4200');
    // T5 at browser level: the interceptor sends the exact token (the stub only checks the format).
    expect(request.headers()['authorization']).toBe('Bearer test-token-123');

    const rows = page.getByTestId('wells').locator('tbody tr');
    await expect(rows).toHaveCount(3);
    await expect(rows.first()).toContainText('W-001');
    await expect(rows.first()).toContainText('Eagle-1');
    await expect(rows.first()).toContainText('1,200 bbl/d');
  });

  test('shows the example-driven empty list', async ({ page }) => {
    await page.goto('/?status=ABANDONED');
    await expect(page.getByTestId('filter')).toHaveText('ABANDONED');
    await expect(page.getByTestId('empty')).toHaveText('No wells match this filter.');
  });

  test('a documented error response is served from the provider example (400 ProblemDetails)', async ({ page }) => {
    // status=PUMPING is exactly the request of the provider's example provider__list_wells_bad_status_400,
    // so the stub returns that documented 400 (ProblemDetails with an `errors` map).
    const apiResponse = page.waitForResponse((r) => r.url().includes('/v2/wells'));
    await page.goto('/?status=PUMPING');

    const response = await apiResponse;
    expect(response.status()).toBe(400);
    expect(response.headers()['content-type']).toContain('application/problem+json');
    expect((await response.json()).errors.status).toBeDefined();
    await expect(page.getByTestId('error')).toHaveText('Request failed: HTTP 400');
  });

  test('a request that breaks the contract is rejected by the stub', async ({ page }) => {
    // DRILLING is not in the WellStatus enum and no example covers it. TypeScript cannot stop it
    // (it comes from the URL), but the strict stub enforces the contract and explains why.
    const apiResponse = page.waitForResponse((r) => r.url().includes('/v2/wells'));
    await page.goto('/?status=DRILLING');

    const response = await apiResponse;
    expect(response.status()).toBe(400);
    expect(await response.text()).toContain('DRILLING');
    await expect(page.getByTestId('error')).toHaveText('Request failed: HTTP 400');
  });
});
