import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { whoWaits, type SignStatus } from './path';
import './owner-path.css';

// Sign first (r50, 3800): on the owner pages of Admin and staff (Fleet, customer service) and on an application: what
// still keeps this owner's cars from being approved, delivered or rented, each item with who it waits on, and one
// "Send reminder" (email, in-app and push) for what waits on the owner.
export function SignGate({ status, refresh, testId = 'sign-gate' }: { status: SignStatus | null; refresh: string[]; testId?: string }) {
  if (!status || !status.sign_first) return null;
  const m = status.missing;
  return (
    <section className="pt-card stack" aria-labelledby={`${testId}-h`} data-testid={testId} data-guide="sign-gate" data-missing={m.length}>
      <div className="pt-card__head sg-head"><h2 className="d4" id={`${testId}-h`}>Agreements before cars</h2>
        {status.master && <span className={`badge sg-badge ${status.master.status === 'signed' ? 'badge--outline' : 'badge--red'}`}>{status.master.title} {status.master.number}: {status.master.status === 'signed' ? 'signed' : 'not signed'}</span>}</div>
      {m.length === 0
        ? <p className="small" data-testid={`${testId}-clear`}>Everything is signed: the master agreement and every car&apos;s Schedule A entry. Approval, delivery and handover go ahead.</p>
        : <>
            <p className="small muted">A car is approved, delivered or rented only once these are done. An approval made before goes through by itself when the owner signs.</p>
            <ul className="ad-list small" data-testid={`${testId}-list`}>{m.map((x, i) => (
              <li key={`${x.code}-${x.vehicle_id ?? ''}-${i}`} data-code={x.code} data-who={x.who}><span><b>{x.label}</b></span><span className="muted">{whoWaits(x)}</span></li>))}</ul>
          </>}
      {status.cars.some((c) => c.waiting_approval) && <p className="small" data-testid={`${testId}-waiting`}>Approved, waiting for the signature: {status.cars.filter((c) => c.waiting_approval).map((c) => c.name).join(', ')}.</p>}
      <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)', alignItems: 'center' }}>
        {status.can_remind && <Act action="owner_sign_reminder" payload={{ owner_id: status.owner_id }} label="Send reminder" variant="primary" refresh={refresh}
          done={`Reminder sent to ${status.email ?? 'the owner'}: email, in-app and push.`} testId={`${testId}-remind`} />}
        {!status.has_login && m.some((x) => x.who === 'owner') && <span className="small muted">No sign-in yet: invite the owner first.</span>}
        {status.last_reminder_at && <span className="small muted">Last sent {new Date(status.last_reminder_at).toLocaleDateString('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric' })}</span>}
        {status.viewer === 'admin' && <Link prefetch={false} className="link small" href={`/admin/owners/${status.owner_id}?tab=terms`}>Agreements</Link>}
      </div>
    </section>
  );
}
