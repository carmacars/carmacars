// A bank feed for local work and tests (Program setting bank_data_provider = fake). Made-up account and payees only.
import type { BankFeed } from './types';

const day = (d: Date) => d.toISOString().slice(0, 10);
export function fakeBank(today: Date = new Date()): BankFeed {
  const ago = (n: number) => day(new Date(today.getTime() - n * 86400000));
  return {
    provider: 'fake', connected: true,
    async accounts() { return [{ ref: 'fake-chq-1', last4: '0001', currency: 'CAD', nickname: 'Test chequing' }]; },
    async balance() { return { balance_cents: 1234500, available_cents: 1200000, as_of: ago(0) }; },
    async transactions(_ref, from) {
      const all = [
        { posted_on: ago(5), amount_cents: 52000, description: 'STRIPE PAYOUT', cheque_number: null, fit_id: 'fake-1', balance_cents: null },
        { posted_on: ago(4), amount_cents: -1500, description: 'MONTHLY FEE', cheque_number: null, fit_id: 'fake-2', balance_cents: null },
        { posted_on: ago(3), amount_cents: -64000, description: 'E-TRANSFER SENT EXAMPLE OWNER', cheque_number: null, fit_id: 'fake-3', balance_cents: null }
      ];
      return all.filter((l) => l.posted_on >= from);
    }
  };
}
