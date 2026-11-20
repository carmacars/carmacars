'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { Act } from '@/features/admin/Act';
import { chargeExtensionCard } from '@/server/actions/offers';

// r48 MR (3101): the money of each approved extension on the booking's Money tab (Admin and the Sales portal): the
// amount, whether it was charged or paid and how, who handles it; "Charge the card on file", "Record a payment" received
// another way, and "Give to" another salesperson or to Admin. The database decides who may do each (an Admin, Finance,
// or the salesperson handling it).
export interface ExtensionRow {
  id: string; seq: number; status: string; new_return_at: string; previous_return_at: string;
  money?: { amount_cents: number; state: string; paid: boolean; paid_at: string | null; method: string | null; method_label: string | null; card: string | null;
    reference: string | null; recorded_by: string | null; handler: string | null; handled_by: string | null; may_charge: boolean;
    link: { status: string; sent_at: string | null } | null };
}

const METHODS: Array<[string, string]> = [['e_transfer', 'e-Transfer'], ['cash', 'Cash'], ['cheque', 'Cheque'], ['bank_transfer', 'Bank transfer'], ['other', 'Another way']];

function how(m: NonNullable<ExtensionRow['money']>): string {
  if (!m.paid) return m.link ? `Pay link ${m.link.status}${m.link.sent_at ? `, sent ${when(m.link.sent_at)}` : ''}` : 'Not charged yet';
  const way = m.card ? `${m.card}` : (m.method_label ?? m.method ?? '');
  return [way, m.reference ? `ref. ${m.reference}` : '', m.paid_at ? when(m.paid_at) : '', m.recorded_by ? `by ${m.recorded_by}` : ''].filter(Boolean).join(', ');
}

export function ExtensionMoney({ rows, booking, refresh, salespeople }: { rows: ExtensionRow[]; booking: string; refresh: string[]; salespeople: Array<[string, string]> }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ id: string; ok: boolean; text: string } | null>(null);
  const shown = rows.filter((r) => ['approved', 'confirmed'].includes(r.status) && r.money);
  if (!shown.length) return null;
  const charge = (r: ExtensionRow) => start(async () => {
    const x = await chargeExtensionCard({ booking, extension: r.id });
    setMsg({ id: r.id, ok: x.ok && x.data.ok, text: x.ok ? (x.data.ok ? 'Charged to the card on file: the extension is confirmed.' : x.data.message ?? 'Not charged.') : x.message });
    router.refresh();
  });
  const to: Array<[string, string]> = [['', 'Choose who'], ...salespeople, ['admin', 'Admin']];
  return (
    <section className="pt-card ad-card stack" data-testid="extension-money" aria-label="Extensions">
      <b className="small">Extensions</b>
      {shown.map((r) => {
        const m = r.money!;
        return (
          <div key={r.id} className="stack" data-testid={`extension-money-${r.seq}`}>
            <div className="row">
              <span>Extension {r.seq}: to {when(r.new_return_at)}, <b>{money(m.amount_cents)}</b></span>
              <span className={m.paid ? 'badge' : 'badge badge--grey'} data-testid={`extension-state-${r.seq}`}>{m.paid ? 'Paid' : 'Waiting for payment'}</span>
            </div>
            <span className="small muted">{how(m)}. Handled by {m.handler ?? 'nobody'}.</span>
            <span className="ad-actions">
              {!m.paid && m.may_charge && <button type="button" className="btn btn--primary btn--sm" disabled={pending} onClick={() => charge(r)} data-testid={`extension-charge-${r.seq}`}>Charge the card on file</button>}
              {!m.paid && <Act ops action="extension_record_payment" payload={{ extension: r.id }} label="Record a payment" testId={`extension-record-${r.seq}`} refresh={refresh} done="Recorded: the extension is confirmed."
                fields={[{ name: 'method', label: 'How it was received', type: 'select', options: METHODS, required: true },
                  { name: 'reference', label: 'Reference (an e-Transfer needs it)', type: 'text' }, { name: 'received_on', label: 'Received on', type: 'date' },
                  { name: 'note', label: 'Note', type: 'text' }]} />}
              <Act ops action="extension_assign" payload={{ extension: r.id }} label="Give to" testId={`extension-assign-${r.seq}`} refresh={refresh} done="Given."
                fields={[{ name: 'to', label: 'Who handles it (the commission is theirs)', type: 'select', options: to, required: true }, { name: 'reason', label: 'Reason', type: 'text', required: true }]} />
            </span>
            {msg?.id === r.id && <p className={msg.ok ? 'small' : 'small ad-late'} role="status">{msg.text}</p>}
          </div>
        );
      })}
    </section>
  );
}
