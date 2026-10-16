import 'server-only';
import { workerToken } from '@/server/listing-worker';

/** The jobs' bearer token (the listing worker's, derived from LINK_SIGNING_KEY), compared in constant time. */
export async function jobAuthorized(req: Request): Promise<boolean> {
  const want = await workerToken();
  const got = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  let d = want.length ^ got.length;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ (got.charCodeAt(i) || 0);
  return d === 0;
}
