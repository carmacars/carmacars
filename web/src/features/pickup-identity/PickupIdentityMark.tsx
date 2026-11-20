import './pickup-identity.css';
import { rpc } from '@/lib/db/repo';
import { t } from '@/features/admin/ui';
import { FLAG_TITLE, outcomeWords, resultLines, type PickupView } from './model';

// On the booking page (Admin and the staff portals): the mark of the pickup identity check (3293) while Fleet and Admin
// have its To do open, and the latest check with what was compared. Nothing shows for a booking never checked, or to
// staff who may neither hand the car over nor review its documents.
export async function PickupIdentityMark({ booking, userId }: { booking: string; userId: string }) {
  const v = (await rpc('server_pickup_identity_view', { p_by: userId, p_booking: booking }, { role: 'service_role', skipViewAs: true }).catch(() => null)) as unknown as PickupView | null;
  if (!v?.staff || !v.last) return null;
  const c = v.last;
  return (
    <section className={v.marked ? 'pid__flag' : 'pid'} aria-label="Pickup identity check" data-testid="pickup-identity-mark" data-marked={v.marked ? 'yes' : 'no'}>
      <b>{v.marked ? FLAG_TITLE : 'Pickup identity check'}</b>
      <p className="small">{c.by_renter ? 'Made by the renter at the self check-in' : `Made by ${c.by ?? 'staff'}`}, {t(c.at)}. {v.marked ? 'Fleet and Admin have an urgent To do. The mark goes when it is done.' : outcomeWords(c.outcome, true)}</p>
      {c.mismatches.length > 0 && <ul className="small">{c.mismatches.map((m) => <li key={m}>{m}</li>)}</ul>}
      {c.coverage_problem && <p className="small"><b>Coverage problem:</b> credit card coverage needs a card in the renter&apos;s own name.</p>}
      <ul className="pid__res">{resultLines(c.results, true).map((l) => <li key={l.key}><span>{l.label}</span><b data-r={l.result}>{l.word}</b></li>)}</ul>
      <p className="small muted">The photos taken at the pickup are with the renter&apos;s licence, under Review the licence.</p>
    </section>
  );
}
