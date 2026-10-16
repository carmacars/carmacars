import Link from 'next/link';
import { $, Card, Table, d } from '@/features/admin/ui';

// Payments recorded by hand in a month, to check against the bank account (migration 0044, app.manual_payments_month).
type Row = Record<string, unknown>;
export interface ManualMonthData { month: string; rows: Row[]; totals: Record<string, number> }
const LABEL: Record<string, string> = { e_transfer: 'e-Transfer', cheque: 'Cheque', cash: 'Cash', bank_transfer: 'Bank transfer', other: 'Other' };

export function ManualMonth({ data, base }: { data: ManualMonthData; base: string }) {
  const m = new Date(`${data.month}T12:00:00Z`);
  const shift = (n: number) => { const x = new Date(m); x.setUTCMonth(x.getUTCMonth() + n); return x.toISOString().slice(0, 10); };
  const title = new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', month: 'long', year: 'numeric' }).format(m);
  const totals = Object.entries(data.totals);
  return (
    <Card title={`Paid another way, ${title}`} testId="manual-month" aside={<span className="small"><Link prefetch={false} className="link" href={`${base}?month=${shift(-1)}`}>Previous month</Link> · <Link prefetch={false} className="link" href={`${base}?month=${shift(1)}`}>Next month</Link></span>}>
      <p className="small">{totals.length ? totals.map(([k, v]) => `${LABEL[k] ?? k} ${$(v)}`).join(' · ') : 'Nothing recorded this month.'} Voided payments are listed but not counted.</p>
      <Table rows={data.rows} empty="No payments recorded by hand this month." cols={[{ key: 'received_on', label: 'Received', render: (r) => d(r.received_on) }, { key: 'method_label', label: 'How' }, { key: 'reference', label: 'Reference' },
        { key: 'for', label: 'For', render: (r) => String(r.invoice_number ?? r.booking_number ?? '') }, { key: 'payer', label: 'From' }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) },
        { key: 'recorded_by_name', label: 'Recorded by' }, { key: 'voided_at', label: 'Voided', render: (r) => (r.voided_at ? `Yes${r.void_reason ? `: ${String(r.void_reason)}` : ''}` : ''), className: 'wrap' }]} />
    </Card>
  );
}
