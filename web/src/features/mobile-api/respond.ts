// How the mobile API answers (release 48): one envelope, one place that turns what a server action returned, threw or
// redirected to into it. No imports besides the contract's types: the unit test runs it in Node (respond.test.ts).
import type { ApiFail } from './contract.ts';

export interface Answer { status: number; body: { ok: true; data: unknown; next?: string } | ApiFail }

const STATUS: Record<string, number> = { auth: 401, expired: 401, credentials: 401, two_step: 403, not_found: 404, rate_limited: 429, busy: 503, update: 426 };

/** What a handler returned: the envelope as it is (a refusal gets its status), anything else wrapped as ok. */
export function answerOf(out: unknown): Answer {
  if (out && typeof out === 'object' && 'ok' in out && typeof (out as { ok: unknown }).ok === 'boolean') {
    const o = out as { ok: boolean; data?: unknown; code?: string; message?: string; fieldErrors?: Record<string, string>; status?: number };
    if (o.ok) return { status: 200, body: { ok: true, data: o.data ?? null } };
    const code = o.code || 'refused';
    return { status: o.status ?? STATUS[code] ?? 400, body: { ok: false, code, message: o.message || 'Not done. Try again.', ...(o.fieldErrors ? { fieldErrors: o.fieldErrors } : {}) } };
  }
  return { status: 200, body: { ok: true, data: out ?? null } };
}

/** What a handler threw. A server action that ends with redirect() succeeded: the app gets where the site would go next.
 *  notFound() is a 404. A refusal of the database is shown as written. Anything else is a plain sentence (the caller
 *  logs the error itself). */
export function answerOfError(e: unknown): Answer & { unexpected?: boolean } {
  const digest = e && typeof e === 'object' && typeof (e as { digest?: unknown }).digest === 'string' ? (e as { digest: string }).digest : '';
  if (digest.startsWith('NEXT_REDIRECT')) {
    const to = digest.split(';')[2] ?? '';
    // a redirect to the sign-in page is the action's way of saying nobody is signed in
    if (/^\/sign-in(\?|$)/.test(to)) return { status: 401, body: { ok: false, code: 'auth', message: 'Sign in first.' } };
    if (/^\/two-step(\?|$)/.test(to)) return { status: 403, body: { ok: false, code: 'two_step', message: 'Two-step sign-in is required.' } };
    return { status: 200, body: { ok: true, data: null, ...(to.startsWith('/') ? { next: to } : {}) } };
  }
  if (digest === 'NEXT_NOT_FOUND' || digest.startsWith('NEXT_HTTP_ERROR_FALLBACK;404')) return { status: 404, body: { ok: false, code: 'not_found', message: 'Not found.' } };
  const err = e as { name?: string; code?: unknown; message?: unknown } | null;
  if (err?.name === 'DbError' && typeof err.message === 'string') {
    const code = err.code === 'two_step' ? 'two_step' : err.code === '42501' ? 'forbidden' : err.code === 'P0002' ? 'not_found' : 'refused';
    return { status: code === 'two_step' || code === 'forbidden' ? 403 : code === 'not_found' ? 404 : 400, body: { ok: false, code, message: err.message.replace(/^.*?ERROR:\s*/, '').slice(0, 400) } };
  }
  if (err?.name === 'ViewAsReadOnly') return { status: 403, body: { ok: false, code: 'forbidden', message: 'Not permitted.' } };
  return { status: 500, unexpected: true, body: { ok: false, code: 'error', message: 'Something went wrong. Please try again.' } };
}
