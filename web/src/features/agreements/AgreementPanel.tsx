import Link from 'next/link';
import { Card } from '@/features/admin/ui';
import { door } from '@/server/door';
import { when } from '@/features/agreement/model';
import { AgreementActions, MissingFields, type Missing } from './AgreementActions';

// The booking page's Agreement card (migration 0143), for an Admin and the assistants: the current version of the two
// rental agreements and every earlier one (what changed, both PDFs, who signed or countersigned), a version waiting for
// signatures (resend the links, or sign on this device), what the agreements still print blank (fill it here; check-out
// stops on what a claim needs unless an Admin overrides with a reason), and the dispute evidence pack.
interface Version {
  id: string; version_no: number; kind: string; material: boolean; status: string; created_at: string; signed_at: string | null; note: string | null;
  countersigned_name: string | null; changes: Array<{ label: string; before: string; after: string; material: boolean }>; carmacars: string | null; blindspot: string | null;
  signers: Array<{ id: string; role: string; name: string; status: string; signed_at: string | null; has_email: boolean; has_mobile: boolean }>;
}
interface State {
  booking_id: string; booking_number: string; status: string; plan_state: string; pending: { kind: string; material: boolean; changes: unknown[] } | null;
  versions: Version[]; waiting: { version_no: number; signers: Array<{ id: string; name: string; role: string; token: string }> } | null;
  missing: Missing[]; overrides: Array<{ at: string; reason: string; by: string | null }>; job: { due_at: string; attempts: number; last_error: string | null } | null; is_admin: boolean;
  disputes: Array<{ id: string; status: string; built_at: string | null; staged_at: string | null; submitted_at: string | null; document_id: string | null; error: string | null; size: number | null }>;
}
const KIND: Record<string, string> = { signed: 'as signed', pickup: 'as picked up', return: 'as returned', change: 'changed', correction: 'corrected' };
const STATUS: Record<string, string> = { signed: 'signed', filed: 'filed', awaiting_signature: 'waiting for signature', superseded: 'replaced' };

export async function AgreementPanel({ b, base, userId, aal, docBase, finance }: { b: { id: string; status: string }; base: string; userId: string; aal?: 'aal1' | 'aal2' | null; docBase: string; finance: boolean }) {
  const s = await door<State>(userId, 'ops_read', 'agreement_state', { booking: b.id }, aal).catch(() => null);
  if (!s) return null;
  const required = s.missing.filter((m) => m.required);
  const current = s.versions.find((v) => v.status !== 'superseded' && v.status !== 'awaiting_signature') ?? s.versions[0];
  const refresh = [base];
  return (
    <Card title="Rental agreements" testId="agreement-panel" tone={s.waiting || required.length ? 'warn' : undefined}>
      <div className="stack">
        {s.versions.length === 0 ? <p className="small muted">The versions start once the rental agreement is signed and countersigned. Until then the open agreement follows the booking by itself.</p> : <>
          {current && <p data-testid="agreement-current">Current: <b>version {current.version_no}</b> ({KIND[current.kind] ?? current.kind}), {STATUS[current.status] ?? current.status} {when(current.signed_at ?? current.created_at)}.
            {current.carmacars && <> <a className="link" href={`${docBase}/${current.carmacars}`} target="_blank" rel="noreferrer">CarmaCars PDF</a></>}
            {current.blindspot && <> · <a className="link" href={`${docBase}/${current.blindspot}`} target="_blank" rel="noreferrer">Blind Spot PDF</a></>}</p>}
          {s.waiting && <div className="alert alert--warn" role="status" data-testid="agreement-waiting"><span className="alert__title">Agreement v{s.waiting.version_no} waiting for signature</span>
            <span>{s.waiting.signers.map((g) => g.name).join(', ')}. The link went by email and text. <span className="row" style={{ display: 'inline-flex', flexWrap: 'wrap', gap: 'var(--s-2)' }}>
              {s.waiting.signers.map((g) => <Link key={g.id} prefetch={false} className="btn btn--ghost btn--sm" href={`/sign/agreement/${g.token}?in_person=1`} data-testid={`agreement-sign-here-${g.role}`}>{g.name.split(' ')[0]} signs on this device</Link>)}</span></span></div>}
          {s.pending && <p className="small muted" data-testid="agreement-pending">A new version ({KIND[s.pending.kind] ?? s.pending.kind}) is being made{s.job?.last_error ? `; the last try failed: ${s.job.last_error}` : '.'}</p>}
          <details data-testid="agreement-history"><summary className="link">Every version ({s.versions.length})</summary>
            <ol className="stack" style={{ paddingLeft: '1.2rem' }} reversed>{s.versions.map((v) => (
              <li key={v.id} className="small" data-testid={`agreement-version-${v.version_no}`}><b>Version {v.version_no}</b>, {KIND[v.kind] ?? v.kind}, {STATUS[v.status] ?? v.status}, {when(v.created_at)}{v.countersigned_name ? `, countersigned by ${v.countersigned_name}` : ''}{v.note ? `. ${v.note}` : ''}.
                {v.carmacars && <> <a className="link" href={`${docBase}/${v.carmacars}`} target="_blank" rel="noreferrer">CarmaCars</a></>}{v.blindspot && <> · <a className="link" href={`${docBase}/${v.blindspot}`} target="_blank" rel="noreferrer">Blind Spot</a></>}
                {v.changes.length > 0 && <ul>{v.changes.map((c, i) => <li key={i}>{c.label}: {c.before} → {c.after}{c.material ? ' (signed again)' : ''}</li>)}</ul>}
                {v.signers.length > 0 && <p className="xs muted">Signers: {v.signers.map((g) => `${g.name} ${g.status === 'signed' ? `signed ${when(g.signed_at)}` : g.status}`).join('; ')}</p>}
              </li>))}</ol>
          </details>
        </>}
        <MissingFields booking={s.booking_id} missing={s.missing} refresh={refresh} isAdmin={s.is_admin} overrides={s.overrides} />
        <AgreementActions booking={s.booking_id} refresh={refresh} waiting={!!s.waiting} finance={finance || s.is_admin} disputes={s.disputes} docBase={docBase} />
      </div>
    </Card>
  );
}
