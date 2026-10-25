import './usage.css';
import Link from 'next/link';
import { door } from '@/server/door';
import { Act } from '@/features/admin/Act';
import { t } from '@/features/admin/ui';
import { PAUSE, paidCost, share, shortLabel, usd, usedUpTitle, type ServiceState } from './model';
import { UsageAllow } from './UsageAllow';

// The usage guard on Admin > To do (migration 0080): one quiet card at 80% of an included allowance, one card when it is
// used up (with "Allow paid usage" where paying is possible), and a banner while emails are held by the plan's limits.
type CardRow = ServiceState & { alert_id: string; level: 80 | 100; title: string; emailed_at: string | null; email_note: string | null };
interface Cards { cards: CardRow[]; emails_held: number }

export async function UsageCards({ userId }: { userId: string }) {
  const u = await door<Cards>(userId, 'ops_read', 'usage_cards').catch(() => null);
  if (!u || (!u.cards.length && !u.emails_held)) return null;
  return (
    <div className="stack" data-testid="usage-cards">
      {u.emails_held > 0 && (
        <p className="alert alert--warn" role="status" data-testid="usage-emails-held"><span><b>{u.emails_held} email{u.emails_held === 1 ? '' : 's'} held.</b> {PAUSE.emailsHeld} <Link prefetch={false} className="link" href="/admin/messages">See the emails</Link></span></p>)}
      {u.cards.map((c) => <UsageCard key={c.alert_id} c={c} />)}
    </div>
  );
}

function UsageCard({ c }: { c: CardRow }) {
  const name = shortLabel(c.label);
  const resets = c.resets_at ? `Resets ${t(c.resets_at)}.` : '';
  if (c.level === 80) {
    return (
      <section className="pt-card ad-card" aria-labelledby={`u-${c.alert_id}`} data-testid={`usage-card-${c.service}`} data-level="80">
        <div className="pt-card__head"><h2 className="d4" id={`u-${c.alert_id}`}>{name} at {share(c.share_bps)} of the included allowance</h2>
          <Act action="usage_alert_dismiss" payload={{ id: c.alert_id }} label="Dismiss" variant="quiet" testId={`usage-dismiss-${c.service}`} /></div>
        <p className="small">{c.used_text} of {c.included_text} used. {resets} Nothing changes yet. When it is used up: {c.when_used_up}</p>
      </section>
    );
  }
  const cost = paidCost(c);
  const paid = c.state === 'paid' && c.decision?.decision === 'allow';
  return (
    <section className="pt-card ad-card ad-card--warn" aria-labelledby={`u-${c.alert_id}`} data-testid={`usage-card-${c.service}`} data-level="100" data-state={c.state}>
      <div className="pt-card__head"><h2 className="d4" id={`u-${c.alert_id}`}>{usedUpTitle(c)}{cost.canPay && !paid ? ': Allow paid usage' : ''}</h2></div>
      <p className="small">{c.used_text} of {c.included_text} used. {resets}</p>
      {c.pause_mode === 'alert' ? (
        <p className="small" data-testid={`usage-never-paused-${c.service}`}><b>Never paused:</b> {c.when_used_up} Estimated cost above the allowance so far: <b>{usd(c.overage_usd)}</b>. {c.upgrade_text ?? ''}</p>
      ) : c.pause_mode === 'hold' ? (
        <p className="small"><b>Held:</b> {c.when_used_up} {c.upgrade_text}</p>
      ) : !cost.canPay ? (
        <p className="small" data-testid={`usage-hard-stop-${c.service}`}><b>Stopped for today, never paid.</b> {c.when_used_up}</p>
      ) : paid ? (
        <p className="small" data-testid={`usage-paid-${c.service}`}>Paid usage allowed until the end of {c.decision!.until === 'day' ? 'today' : 'this month'}, up to {usd(c.decision!.cap_usd)} ({usd(c.decision!.spent_usd)} used so far){c.decision!.by ? `, by ${c.decision!.by}` : ''}.</p>
      ) : (
        <>
          <p className="small"><b>{c.decision?.decision === 'keep_paused' ? 'Kept paused.' : 'Paused until you answer.'}</b> {c.when_used_up}</p>
          <p className="small muted">{cost.rate} {cost.example}</p>
        </>
      )}
      {c.pause_mode === 'pause' && !paid && cost.canPay && <UsageAllow s={c} testId={`usage-allow-${c.service}`} />}
      <p className="small"><Link prefetch={false} className="link" href="/admin/settings/usage">Settings &gt; Usage</Link></p>
    </section>
  );
}
