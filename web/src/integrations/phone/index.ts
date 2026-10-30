import 'server-only';
import { env } from '@/lib/env';
import type { PhoneLine } from './types';
import { fakeLine } from './fake';
import { quoLine } from './quo';
import { fakeBook, quoBook } from './contacts';
import type { ContactsBook } from '@/features/phone/quo-contacts';

// QUO_PROVIDER=quo in production (the deploy); fake elsewhere.
export function phoneLine(): PhoneLine {
  const e = env();
  return e.QUO_PROVIDER === 'quo' ? quoLine(e.QUO_API_KEY, e.QUO_API_BASE) : fakeLine();
}

/** Quo contacts (0190): the same provider and key as the line; no key: the sync records why and waits. */
export function contactsBook(): ContactsBook {
  const e = env();
  return e.QUO_PROVIDER === 'quo' ? quoBook(e.QUO_API_KEY, e.QUO_API_BASE) : fakeBook();
}

/** The local fake's webhook secret: the end-to-end tests sign their deliveries with it. Never used in production. */
export const LOCAL_QUO_WEBHOOK_SECRET = 'whsec_' + 'Y2FybWFjYXJzLWxvY2FsLXF1by13ZWJob29rLXNlY3JldA==';
export function webhookSecrets(): string[] {
  const e = env();
  if (e.QUO_WEBHOOK_SECRET) return e.QUO_WEBHOOK_SECRET.split(/\s+/).filter(Boolean);
  return e.QUO_PROVIDER === 'fake' && e.APP_ENV !== 'production' ? [LOCAL_QUO_WEBHOOK_SECRET] : [];
}
export type * from './types';
