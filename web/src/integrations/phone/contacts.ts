import { listContactsPage, throttle, upsertContact, type QuoOptions } from '@/features/phone/quo-api';
import type { ContactsBook } from '@/features/phone/quo-contacts';

// Quo contacts (migration 0190): the CarmaCars workspace's contact list through Quo's public API with the same key as
// the texts (QUO_API_KEY, a Worker secret; no other key). Calls are at least 150 ms apart (Quo allows 10 a second).
export function quoBook(key: string | undefined, base?: string): ContactsBook {
  const o: QuoOptions = { key: key ?? '', base, fetch: throttle(fetch, 150) };
  return {
    name: 'quo', ready: !!key, missing: key ? null : 'QUO_API_KEY is not set',
    async listPage(token) {
      const p = await listContactsPage(o, token);
      return { contacts: p.contacts.map((c) => ({ id: c.id, phones: c.phones.map((x) => x.value) })), next: p.next };
    },
    upsert: (p, quoId, externalId) => upsertContact(o, p, quoId, externalId)
  };
}

// For local work and tests: the contacts "in Quo" are kept here, never sent.
export interface FakeContact { id: string; externalId: string; number: string; firstName: string; lastName: string | null; email: string | null; company: string | null; role: string | null }
export const fakeContacts = new Map<string, FakeContact>();
export function fakeBook(): ContactsBook {
  return {
    name: 'fake', ready: true, missing: null,
    async listPage() { return { contacts: [], next: null }; },
    async upsert(p, quoId, externalId) {
      const found = (quoId ? fakeContacts.get(quoId) : undefined) ?? [...fakeContacts.values()].find((c) => c.externalId === externalId);
      const id = found?.id ?? `CTfake${crypto.randomUUID().replace(/-/g, '').slice(0, 20)}`;
      fakeContacts.set(id, { id, externalId, number: p.number, firstName: p.first_name, lastName: p.last_name, email: p.email, company: p.company, role: p.role });
      return { id, action: found ? 'updated' : 'created' };
    }
  };
}
