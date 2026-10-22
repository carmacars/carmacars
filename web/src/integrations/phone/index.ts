import 'server-only';
import { env } from '@/lib/env';
import type { PhoneLine } from './types';
import { fakeLine } from './fake';
import { quoLine } from './quo';

// QUO_PROVIDER=quo in production (the deploy); fake elsewhere.
export function phoneLine(): PhoneLine {
  const e = env();
  return e.QUO_PROVIDER === 'quo' ? quoLine(e.QUO_API_KEY, e.QUO_API_BASE) : fakeLine();
}

/** The local fake's webhook secret: the end-to-end tests sign their deliveries with it. Never used in production. */
export const LOCAL_QUO_WEBHOOK_SECRET = 'whsec_' + 'Y2FybWFjYXJzLWxvY2FsLXF1by13ZWJob29rLXNlY3JldA==';
export function webhookSecrets(): string[] {
  const e = env();
  if (e.QUO_WEBHOOK_SECRET) return e.QUO_WEBHOOK_SECRET.split(/\s+/).filter(Boolean);
  return e.QUO_PROVIDER === 'fake' && e.APP_ENV !== 'production' ? [LOCAL_QUO_WEBHOOK_SECRET] : [];
}
export type * from './types';
