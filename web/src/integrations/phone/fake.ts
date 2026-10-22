import type { PhoneLine } from './types';

// For local work and tests: every text "sent" is kept here (and in the database's outbox and thread), never sent.
// FAKE_QUO_FAIL=1 makes every send fail like Quo refusing it.
export const fakeSent: Array<{ from: string; to: string; body: string; id: string; at: string }> = [];
export function fakeLine(): PhoneLine {
  return {
    name: 'fake', ready: true,
    async sendText(p) {
      if (process.env.FAKE_QUO_FAIL === '1') return { ok: false, id: null, error: 'Quo 400: the fake line is set to fail', permanent: true };
      const id = `ACfake${crypto.randomUUID().replace(/-/g, '').slice(0, 20)}`;
      fakeSent.push({ ...p, id, at: new Date().toISOString() });
      return { ok: true, id };
    }
  };
}
