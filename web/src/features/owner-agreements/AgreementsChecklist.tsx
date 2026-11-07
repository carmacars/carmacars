import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { d } from '@/features/admin/ui';

// Admin > Owners > Agreements (migration 0640): each owner's required agreements for their deal (the program set of
// their pay model with the Title-Holding and Lease Agreement, an Additional Vehicle Schedule, the partner agreement, a
// Referral Override Agreement per referral), whether each is signed, sent, not sent or missing, and Send (the email
// with the link to sign in the owner portal).
export interface AgreementItem { doc: 'packet' | 'partner' | 'referral'; kind?: string; link_id?: string; title: string; number?: string | null;
  status: 'signed' | 'sent' | 'not_sent' | 'missing'; why?: string; signed_at?: string | null; awaiting_lawyer?: boolean }
export interface AgreementOwner { owner_id: string; name: string; email: string | null; has_login: boolean; pay_model: string; last_sent_at: string | null; items: AgreementItem[] }

const STATUS: Record<AgreementItem['status'], [string, string]> = {
  signed: ['Signed', ''], sent: ['Sent, not signed', 'badge--outline'], not_sent: ['Not sent', 'badge--red'], missing: ['Missing', 'badge--red']
};
export const openCount = (o: AgreementOwner) => o.items.filter((i) => i.status !== 'signed').length;

export function AgreementsChecklist({ rows, refresh }: { rows: AgreementOwner[]; refresh: string[] }) {
  if (!rows.length) return <p className="pt-empty muted">Every owner has signed every agreement their deal needs.</p>;
  return (
    <ul className="ow-rows" data-testid="agreements-checklist">{rows.map((o) => (
      <li key={o.owner_id} data-owner={o.owner_id}>
        <Link prefetch={false} className="ow-row-link" href={`/admin/owners/${o.owner_id}?tab=terms`}>{o.name}</Link>
        <span className="ow-meta"><span>{o.pay_model === 'fleet_lease' ? 'Fleet lease' : o.pay_model === 'flat_rate' ? 'Flat monthly' : 'Revenue split'}</span>
          {o.last_sent_at && <span>last sent {d(o.last_sent_at)}</span>}{!o.has_login && <span className="badge badge--outline">No sign-in yet: invite first</span>}</span>
        <ul className="ad-list small" style={{ flex: '1 1 100%' }}>{o.items.map((i) => {
          const [label, cls] = STATUS[i.status];
          return (
            <li key={`${i.doc}-${i.kind ?? ''}-${i.link_id ?? ''}`} data-doc={i.doc} data-status={i.status}>
              <span><b>{i.title}</b>{i.number ? ` · ${i.number}` : ''} <span className={`badge ${cls}`}>{label}</span>{i.awaiting_lawyer && <> <span className="badge badge--outline">Awaiting lawyer OK</span></>}
                {i.status === 'signed' && i.signed_at ? ` ${d(i.signed_at)}` : ''}{i.why ? <span className="muted"> {i.why}</span> : null}</span>
              {i.status !== 'signed' && i.status !== 'missing' && o.has_login && o.email && // the Title-Holding and Lease Agreement is signed with the program set: its one Send is on the Enrollment line
                (i.doc !== 'packet' || i.kind !== 'title_holding') &&
                <Act action="owner_agreement_send" payload={{ owner: o.owner_id, doc: i.doc, link: i.link_id ?? null }} label={i.status === 'sent' ? 'Send again' : 'Send'}
                  variant={i.status === 'sent' ? 'ghost' : 'primary'} refresh={refresh} done={`Sent to ${o.email}.`} testId={`agreement-send-${o.owner_id}-${i.doc}${i.link_id ? `-${i.link_id}` : ''}`} />}
            </li>);
        })}</ul>
      </li>))}</ul>
  );
}
