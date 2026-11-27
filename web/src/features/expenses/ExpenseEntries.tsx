import { $, Table, d } from '@/features/admin/ui';

// The expenses logged from receipts (5143), newest first, with their photos (opened through the staff or Admin file route).
export type ExpenseEntry = { id: string; expense_on: string; vendor: string | null; category_label: string | null; description: string; amount_cents: number; hst_cents: number;
  payer: 'company' | 'owner'; vehicle_name: string | null; owner_status: string | null; voided: boolean | null; photos: string[]; by: string | null };

export function ExpenseEntries({ rows, base }: { rows: ExpenseEntry[]; base: '/admin' | '/staff' }) {
  return (
    <Table<ExpenseEntry & Record<string, unknown>> testId="expense-entries" rows={rows as Array<ExpenseEntry & Record<string, unknown>>} caption="Expenses logged from receipts"
      empty="No expense logged from a receipt yet. Take a photo of a receipt above to log one."
      cols={[{ key: 'expense_on', label: 'Date', render: (r) => d(r.expense_on) }, { key: 'vendor', label: 'Shop', render: (r) => r.vendor ?? '' },
        { key: 'category_label', label: 'Category', className: 'wrap' }, { key: 'vehicle_name', label: 'Car', render: (r) => r.vehicle_name ?? 'No car' },
        { key: 'payer', label: 'Paid by', render: (r) => (r.payer === 'owner' ? `Owner's statement${r.owner_status && r.owner_status !== 'open' ? ` (${r.owner_status})` : ''}` : r.voided ? 'CarmaCars (void)' : 'CarmaCars') },
        { key: 'amount_cents', label: 'Total', num: true, render: (r) => $(r.amount_cents + r.hst_cents) },
        { key: 'photos', label: 'Receipt', render: (r) => <span className="row">{r.photos.map((p, i) => <a key={p} className="link" href={`${base}/documents/${p}`} target="_blank" rel="noopener">Photo {i + 1}</a>)}</span> },
        { key: 'by', label: 'Logged by', render: (r) => r.by ?? '' }]} />
  );
}
