// r48 integration: tells a connection that was closed under a call (a cancelled Worker request, a restarted database) from
// a SQL error, so local.ts drops the pool that holds it instead of reusing it.
/** A connection the other side or the runtime closed (a cancelled request, a restarted database), not a SQL error. */
export function isClosedConnection(e: unknown): boolean {
  const x = e as { code?: unknown; message?: unknown } | null;
  const code = typeof x?.code === 'string' ? x.code : '';
  return /^(CONNECTION_(CLOSED|DESTROYED|ENDED)|ECONNRESET|EPIPE)$/.test(code) || /socket has been closed|socket (is )?closed|Connection terminated|write (EPIPE|ECONNRESET)/i.test(String(x?.message ?? ''));
}
