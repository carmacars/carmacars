import Link from 'next/link';
import { money } from '@/lib/format';
import { ManualPaymentForm, PaperSignatureForm, type PaperDoc } from './ManualRecords';

// What each owner signs and pays to get their cars on the road (app.owner_signables, migration 0044), with how each
// was done and the two quick actions: Record payment (an invoice) and Record paper signature (a document).
export interface ChecklistItem {
  code: string; group: 'sign' | 'pay'; label: string; status: 'done' | 'open' | 'not_needed'; method: string | null; date: string | null; detail?: string | null;
  vehicle_name?: string | null; doc_type?: string; target_id: string; invoice_id?: string; invoice_number?: string; balance_cents?: number; payable?: boolean; document_id?: string | null;
}
export interface OwnerChecklistRow { owner_id: string; legal_name: string; items: ChecklistItem[]; open: number; done: number; paper: number }

export const HOW: Record<string, string> = {
  portal: 'in the portal', screen: 'on screen', paper: 'on paper', upload: 'uploaded', typed: 'in the portal', drawn: 'in the portal', debit: 'by debit', card: 'by card',
  pre_authorized_debit: 'by debit', e_transfer: 'by e-Transfer', cheque: 'by cheque', cash: 'in cash', bank_transfer: 'by bank transfer', other: 'another way', deducted: 'from payouts', automatic: 'automatically'
};
const day = (iso: string | null | undefined) => (iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(`${iso.slice(0, 10)}T12:00:00Z`)) : '');
const WITNESSES: Record<string, 0 | 1 | 2> = { form_c: 1, form_d: 2 };

/** One item's status line: "Signed on paper, Oct 3, 2026" or the open detail. */
export function itemStatus(i: ChecklistItem): string {
  if (i.status === 'not_needed') return 'Not needed';
  if (i.status === 'done') return `${i.group === 'pay' ? 'Paid' : 'Signed'}${i.method && HOW[i.method] ? ` ${HOW[i.method]}` : ''}${i.date ? `, ${day(i.date)}` : ''}`;
  return i.detail || (i.group === 'pay' ? 'Not paid' : 'Not signed');
}

/** The paper documents an owner can sign: every open signable item (agreement, schedules, forms, debit agreement). */
export function paperDocs(items: ChecklistItem[], signer: string): PaperDoc[] {
  const seen = new Set<string>();
  const out: PaperDoc[] = [];
  for (const i of items) {
    if (i.group !== 'sign' || i.status !== 'open' || !i.doc_type) continue;
    const key = `${i.doc_type}:${i.target_id}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ doc_type: i.doc_type, target_id: i.target_id, signer, witnesses: WITNESSES[i.doc_type] ?? 0,
      label: i.doc_type === 'owner_agreement' ? 'Owner program agreement with its schedules (every open schedule)' : `${i.label}${i.vehicle_name ? `, ${i.vehicle_name}` : ''}` });
  }
  return out;
}

export function ChecklistItems({ items }: { items: ChecklistItem[] }) {
  return (
    <ul className="ck-items">
      {items.filter((i) => i.status !== 'not_needed').map((i, n) => (
        <li key={`${i.code}-${i.target_id}-${n}`} data-status={i.status} data-code={i.code}>
          <span className={`ck-dot is-${i.status}`} aria-hidden="true" />
          <span><b>{i.label}</b>{i.vehicle_name && i.code !== 'upfront_payment' && i.code !== 'tracker_payment' ? `, ${i.vehicle_name}` : ''}: <span data-testid="checklist-status">{itemStatus(i)}</span></span>
        </li>
      ))}
    </ul>
  );
}

/** The full checklist of one owner with the actions (the owner screen and the bulk view). */
export function OwnerChecklist({ row, signer, today, refresh }: { row: OwnerChecklistRow; signer: string; today: string; refresh: string[] }) {
  const pay = row.items.filter((i) => i.group === 'pay' && i.payable && i.invoice_id);
  const docs = paperDocs(row.items, signer);
  return (
    <div className="stack" data-testid="owner-checklist" data-owner={row.owner_id}>
      <ChecklistItems items={row.items} />
      {(pay.length > 0 || docs.length > 0) && (
        <div className="stack">
          {pay.map((i) => (
            <div key={i.invoice_id} className="stack">
              <p className="small">{i.label}: {money(i.balance_cents ?? 0, { cents: true })} owing</p>
              <ManualPaymentForm prefix="ck-pay" invoice={i.invoice_id} number={i.invoice_number!} balance={i.balance_cents ?? 0} today={today} refresh={refresh} />
            </div>
          ))}
          <PaperSignatureForm docs={docs} today={today} refresh={refresh} />
        </div>
      )}
    </div>
  );
}

export function ChecklistOwnerLink({ row }: { row: OwnerChecklistRow }) {
  return <Link prefetch={false} className="link" href={`/admin/owners/${row.owner_id}#checklist`}>{row.legal_name}</Link>;
}
