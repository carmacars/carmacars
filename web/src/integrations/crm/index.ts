import 'server-only';
import { env } from '@/lib/env';
import { createGhl, type Ghl } from '@/features/partner-crm/ghl';
import { fakeGhlFetch, fakeState, type FakeState } from '@/features/partner-crm/fake-ghl';

// The partner CRM link (migration 0147): GoHighLevel's API v2 with each partner's own Private Integration token (kept in
// Supabase Vault, read by the server for the call only), or the in-memory stand-in for local work and tests.
// CRM_PROVIDER=gohighlevel | fake; unset: gohighlevel in production, fake elsewhere.
let fake: { state: FakeState; fetch: typeof fetch } | null = null;

export function crmProvider(): 'gohighlevel' | 'fake' {
  const e = env();
  return e.CRM_PROVIDER ?? (e.APP_ENV === 'production' ? 'gohighlevel' : 'fake');
}

export function crmClient(o: { token: string; locationId: string; version?: string }): Ghl {
  if (crmProvider() === 'fake') {
    fake ??= (() => { const state = fakeState(o.locationId); return { state, fetch: fakeGhlFetch(state) }; })();
    if (fake.state.location.id !== o.locationId) fake.state.location.id = o.locationId;
    return createGhl({ ...o, fetch: fake.fetch });
  }
  return createGhl(o);
}
