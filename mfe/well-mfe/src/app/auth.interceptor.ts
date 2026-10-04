import { HttpInterceptorFn } from '@angular/common/http';

/**
 * Stand-in for the real OAuth2 library (e.g. MSAL's interceptor): adds the bearer token to every
 * API call. The prototype's services accept the fixed test token "test-token-123".
 */
export const TEST_TOKEN = 'test-token-123';

export const authInterceptor: HttpInterceptorFn = (req, next) =>
  next(req.clone({ setHeaders: { Authorization: `Bearer ${TEST_TOKEN}` } }));
