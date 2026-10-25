// Raw database errors never reach staff screens (0151). The database's own refusals are written for people ("Do not
// release the car: ...", "Enter the e-Transfer reference number") and pass through as they are. A raw PostgreSQL error
// (a constraint name, a type cast, a missing column, a timeout) becomes a plain sentence with a short reference, and the
// original is logged on the server with that reference, the call and its code, with email addresses and phone numbers
// masked.

export interface DbLike { message?: unknown; code?: unknown }

const RAW: RegExp[] = [
  /violates (check|foreign key|unique|not-null|exclusion) constraint/i,
  /duplicate key value/i,
  /null value in column/i,
  /invalid input (syntax|value) for/i,
  /value too long for type/i,
  /out of range for type/i,
  /(column|relation|function|operator|type|schema) .* does not exist/i,
  /record ".*" has no field/i,
  /is ambiguous/i,
  /syntax error at or near/i,
  /cannot cast type/i,
  /malformed (array|record) literal/i,
  /division by zero/i,
  /permission denied for/i,
  /could not serialize access/i,
  /deadlock detected/i,
  /canceling statement due to/i,
  /query returned more than one row/i,
  /structure of query does not match/i,
  /there is no unique or exclusion constraint/i,
  /current transaction is aborted/i,
  /connection (terminated|refused|reset)|ECONNREFUSED|ECONNRESET|server closed the connection/i,
  /new row for relation/i,
  /in a non-volatile function/i,
  /^Unknown (action|screen) /i
];

/** True for an error the database raised itself rather than one of its written refusals. */
export function isRawDbError(e: DbLike | null | undefined): boolean {
  const m = typeof e?.message === 'string' ? e.message : '';
  if (!m) return false;
  const code = typeof e?.code === 'string' ? e.code : '';
  if (/^(08|53|57|58|XX|42P|428|427|4270|42883|42703|42804)/.test(code) && !/^42501$/.test(code)) return true;
  return RAW.some((r) => r.test(m));
}

/** The sentence a person reads for a raw error. */
export function friendlyText(e: DbLike, ref: string): string {
  const m = typeof e.message === 'string' ? e.message : '';
  const code = typeof e.code === 'string' ? e.code : '';
  let what = 'That did not go through and nothing was changed.';
  if (code === '23505' || /duplicate key value/i.test(m)) what = 'That is already recorded (it may have been saved a moment ago). Refresh the page to see it.';
  else if (code === '23503' || /foreign key constraint/i.test(m)) what = 'Something this refers to has changed or no longer exists. Refresh the page and try again.';
  else if (code === '23502' || code === '23514' || /null value in column|check constraint/i.test(m)) what = 'A value is missing or not allowed here. Check what you entered and try again.';
  else if (code === '22P02' || code === '22007' || code === '22008' || code === '22003' || /invalid input|out of range|value too long/i.test(m)) what = 'One of the values is not in the expected format. Check what you entered and try again.';
  else if (code === '40001' || code === '40P01' || code === '57014' || /could not serialize|deadlock|canceling statement/i.test(m)) what = 'The system was busy and nothing was changed. Try again in a moment.';
  else if (/^08|^53|^57/.test(code) || /connection|ECONN/i.test(m)) what = 'The system could not be reached and nothing was changed. Try again in a moment.';
  return `${what} If it happens again, tell the office: reference ${ref}.`;
}

/** Email addresses, phone numbers and long digit runs masked, for the server log. */
export function maskPersonal(s: string): string {
  return s.replace(/[^\s@()'"=,]+@[^\s@()'"=,]+\.[a-z]{2,}/gi, '[email]').replace(/\+?\d[\d\s().-]{7,}\d/g, '[number]');
}

export function errorRef(): string {
  const n = Math.floor(Math.random() * 36 ** 6);
  return `E-${n.toString(36).toUpperCase().padStart(6, '0')}`;
}

/** Log a raw error and return the error to throw in its place (same class shape: message and code). */
export function friendlyDbError<E extends DbLike>(e: E, context: Record<string, unknown> = {}): E | Error & { code?: string } {
  if (!isRawDbError(e)) return e;
  const ref = errorRef();
  try {
    console.error(JSON.stringify({ level: 'error', kind: 'db_raw_error', ref, code: e.code ?? null, message: maskPersonal(String(e.message ?? '')).slice(0, 600),
      ...Object.fromEntries(Object.entries(context).map(([k, v]) => [k, typeof v === 'string' ? maskPersonal(v) : v])) }));
  } catch { /* logging never fails the request */ }
  const out = new Error(friendlyText(e, ref)) as Error & { code?: string; ref?: string };
  out.name = 'DbError';
  out.code = 'friendly';
  out.ref = ref;
  return out;
}
