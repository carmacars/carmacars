import type { EmailAdapter, OutgoingEmail } from './types';

export function fakeEmail(): EmailAdapter & { sent: OutgoingEmail[] } {
  const sent: OutgoingEmail[] = [];
  return { name: 'fake', sent, async send(m) { sent.push(m); return { id: `fake_email_${sent.length}` }; } };
}
