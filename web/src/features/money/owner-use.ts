// r48 RW (3270, 3272): the owner-use charges of an Owner Booking on its Money tab, in words.
export interface OwnerUseInvoice {
  id: string; invoice_number: string; status: string; total_cents: number; balance_cents: number;
  state: 'card' | 'debit' | 'pay_now' | 'deducting' | null; collect_by: string | null; issued_on: string | null;
  deduct_after: string | null; reminders: number;
  lines: Array<{ description: string; amount_cents: number; note: string | null }>;
}
export interface OwnerUse {
  owner_use: boolean; on: boolean;
  waiting: Array<{ id: string; description: string; amount_cents: number; evidence_status: string | null; missing: string[] | null }>;
  invoices: OwnerUseInvoice[];
}

/** where one invoice of owner-use charges stands, in plain words */
export function ownerUseStateWords(i: Pick<OwnerUseInvoice, 'status' | 'state' | 'balance_cents' | 'deduct_after' | 'reminders'>, day: (d: string) => string): { word: string; text: string; warn: boolean } {
  if (i.status === 'paid' || i.balance_cents <= 0) return { word: 'Paid', text: 'Paid by the owner.', warn: false };
  const by = i.deduct_after ? day(i.deduct_after) : 'the next statement cut-off';
  switch (i.state) {
    case 'card': return { word: 'Charging the card', text: 'Charged to the owner\'s card on file; waiting for the card to settle.', warn: false };
    case 'debit': return { word: 'Bank debit', text: 'A bank debit from the owner\'s account was started the same day.', warn: false };
    case 'deducting': return { word: 'From the statement', text: 'Not paid in time: it is deducted from the owner\'s next statement as its own line.', warn: true };
    default: return {
      word: 'Waiting for the owner',
      text: `No card on file or the charge failed, so the owner was sent the invoice with a pay link${i.reminders ? ` (${i.reminders} reminder${i.reminders === 1 ? '' : 's'} sent)` : ''}. If it is not paid by ${by}, it is deducted from the next statement.`,
      warn: true,
    };
  }
}
