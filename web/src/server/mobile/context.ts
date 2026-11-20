import { AsyncLocalStorage } from 'node:async_hooks';

// The native app's session (release 48, apps/carmacars-native). The app has no cookies: each call to /api/m/v1 carries
// the same access token the site keeps in its session cookie, as "Authorization: Bearer <token>". The route checks the
// token and then runs the call inside this context; the sign-in adapters (src/lib/auth) read the token from here before
// they look for a cookie, so every existing server action and database call sees the same signed-in person, with the
// same checks, as it would for the website. Nothing outside /api/m/v1 ever sets it: a bearer token sent to any other
// address is ignored.
export interface MobileCall { token: string }

// one store for the whole server, however the bundler splits the modules that import this file
const KEY = Symbol.for('carmacars.mobile.call');
const g = globalThis as unknown as Record<symbol, AsyncLocalStorage<MobileCall> | undefined>;
const store = (g[KEY] ??= new AsyncLocalStorage<MobileCall>());

/** Runs `fn` as the person whose access token this is; an empty token is a call with nobody signed in (the session
 *  cookies of a browser are never read inside a mobile call). */
export function asMobileCall<T>(token: string, fn: () => Promise<T>): Promise<T> {
  return store.run({ token }, fn);
}

/** The app's access token while one of its calls is running ('' when nobody is signed in), else null (every website request). */
export function mobileToken(): string | null {
  return store.getStore()?.token ?? null;
}
/** True while a call of the native app is running. */
export const inMobileCall = (): boolean => store.getStore() !== undefined;
