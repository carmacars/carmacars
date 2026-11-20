import Link from '@/components/Link';
import { door } from '@/server/door';
import { Act } from '@/features/admin/Act';
import { CopyLink } from '@/features/portal/CopyLink';
import { codeDayOptions, days, endingSoon, fill, fmtDay, headline, pct, progressLine, tierFill, tierLine, type Progress, type StaffRewards } from './model';

// My rewards (release 48, migration 3261; the owner, Nov 20: "Staff get perks for renting cars out: free rentals they earn
// + discounts from day one"): on every staff portal. The card on the portal home (compact) and the page (everything): the
// discount and its code, the month's tier, progress to the next free day, free days and their codes, the rules. Remote
// and international staff see why there are no rental perks on their account. Every number is the database's.
const torontoToday = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto' }).format(new Date());

export async function loadMyRewards(userId: string, aal?: 'aal1' | 'aal2' | null): Promise<StaffRewards | null> {
  return door<StaffRewards>(userId, 'ops_read', 'my_rewards', {}, aal).catch(() => null);
}

function Bar({ p, label, text, testId, complete }: { p: number; label: string; text: string; testId: string; complete?: boolean }) {
  return (
    <div className="ck-progress rw-bar" data-testid={testId} data-complete={complete || undefined}>
      <div className="ck-progress__bar" role="progressbar" aria-label={label} aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(p * 100)} aria-valuetext={text}>
        <span className="ck-progress__fill" style={{ ['--p' as string]: String(p) }} />
      </div>
      <p className="ck-progress__text small">{text}</p>
    </div>
  );
}
const EarnBar = ({ p, k }: { p: Progress; k: string }) => <Bar p={fill(p.toward, p.per)} label={p.label} text={progressLine(p)} testId={`my-rewards-bar-${k}`} />;

/** The compact card of a portal home: the headline, the nearest bar, a link to the page. Nothing for an Admin (not staff). */
export async function MyRewardsCard({ userId, aal, href }: { userId: string; aal?: 'aal1' | 'aal2' | null; href: string }) {
  const r = await loadMyRewards(userId, aal);
  if (!r?.member) return null;
  const p = r.progress?.sales ?? r.progress?.field;
  return (
    <section className="pt-card ad-card stack rw-card" data-testid="my-rewards-card" aria-labelledby="mrc-t" data-eligible={r.eligible}>
      <div className="rw-card__head"><div><p className="pu-eyebrow">My rewards</p><h2 className="d4" id="mrc-t">{headline(r)}</h2></div>
        <Link prefetch={false} className="btn btn--ghost btn--sm" href={href} data-testid="my-rewards-open">Open My rewards</Link></div>
      {!r.eligible ? <p className="small" data-testid="my-rewards-why">{r.why_not}</p> : <>
        {r.sales && r.month && <Bar p={tierFill(r)} label="This month's tier" text={tierLine(r)} testId="my-rewards-card-tier" complete={!r.month.next} />}
        {p && <EarnBar p={p} k="card" />}
      </>}
    </section>
  );
}

/** The whole of My rewards (the page of the staff portal and of the field portal). */
export function MyRewards({ r, refresh, bookHref = '/cars' }: { r: StaffRewards; refresh: string[]; bookHref?: string }) {
  if (!r.eligible || !r.discount) {
    return (
      <section className="pt-card stack rw-card" data-testid="my-rewards" data-eligible="false">
        <p className="pu-eyebrow">My rewards</p>
        <h2 className="d3">{headline(r)}</h2>
        <p data-testid="my-rewards-why">{r.why_not ?? 'Staff rewards are not on for this account.'}</p>
        {r.frozen && (r.free_days?.balance ?? 0) > 0 && <p className="small muted">You keep the {days(r.free_days!.balance)} you earned. They can be used again when your access is back, until they end.</p>}
      </section>
    );
  }
  const free = r.free_days ?? { balance: 0, lots: [], codes: [] };
  const soon = endingSoon(free.lots, torontoToday());
  const opts = codeDayOptions(free.balance);
  return (
    <div className="stack-lg rw-rewards" data-testid="my-rewards" data-eligible="true" data-tier={r.discount.tier}>
      <section className="pt-card stack rw-card" aria-labelledby="mr-disc">
        <p className="pu-eyebrow">Your discount</p>
        <h2 className="d3" id="mr-disc">{pct(r.discount.bps)} off your own rentals</h2>
        {r.discount.code ? (
          <div className="rw-code" data-testid="my-rewards-code-row">
            <span className="rw-code__label">Your code</span><code className="rw-code__value" data-testid="my-rewards-code">{r.discount.code}</code>
            <CopyLink url={r.discount.code} label="Copy the code" />
          </div>
        ) : <p className="small muted">Your code is being made. Reload in a moment.</p>}
        <p className="small">Type it in the promo code box when you send a request, signed in as yourself. {r.has_renter ? '' : 'Your first request makes your renter profile.'}</p>
        <p><Link prefetch={false} className="btn btn--primary" href={bookHref} data-testid="my-rewards-book">Find a car</Link></p>
        {r.sales && r.month && r.tiers && (<>
          <ul className="rw-tiers" aria-label="Tiers by rental days booked in a month">
            {r.tiers.map((t) => (
              <li key={t.code} className="rw-tier" data-on={t.code === r.discount!.tier || undefined} data-testid={`my-rewards-tier-${t.code}`}>
                <b>{t.name}</b><span>{pct(t.bps)} off</span>
                <small>{t.days > 0 ? `from ${t.days} rental days a month` : 'from day one'}{t.bonus_days ? `, plus ${days(t.bonus_days)} free` : ''}</small>
              </li>))}
          </ul>
          <Bar p={tierFill(r)} label="This month's tier" text={tierLine(r)} testId="my-rewards-tier-bar" complete={!r.month.next} />
          <p className="small muted">A tier you reach lasts through the next month. The month&apos;s top seller gets {r.top_seller_days === 2 ? 'a free weekend' : `${days(r.top_seller_days ?? 0)} free`}.</p>
        </>)}
      </section>

      <section className="pt-card stack rw-card" aria-labelledby="mr-free">
        <p className="pu-eyebrow">Free rental days</p>
        <h2 className="d3" id="mr-free" data-testid="my-rewards-balance">{days(free.balance)} to use</h2>
        {r.progress?.sales && <EarnBar p={r.progress.sales} k="sales" />}
        {r.progress?.field && <EarnBar p={r.progress.field} k="field" />}
        {soon.length > 0 && <p className="alert alert--warn" role="status" data-testid="my-rewards-ending"><span>{days(soon.reduce((n, l) => n + l.left, 0))} {soon.reduce((n, l) => n + l.left, 0) === 1 ? 'ends' : 'end'} by {fmtDay(soon[soon.length - 1]!.expires_on)}. Use {soon.length === 1 && soon[0]!.left === 1 ? 'it' : 'them'} first.</span></p>}
        {opts.length > 0 ? (
          <Act ops action="my_rewards_code" label="Get a free-day code" variant="primary" title="A code for free days" submitLabel="Make my code" refresh={refresh}
            done="Your code is ready below." testId="my-rewards-get-code"
            fields={[{ name: 'days', label: 'Free days for one rental', type: 'select', required: true, value: '1', options: opts.map((n) => [String(n), days(n)] as [string, string]),
              hint: 'One code a rental. An unused code can be cancelled and its days come back.' }]} />
        ) : <p className="small muted" data-testid="my-rewards-none">No free days to use yet. They show here the moment you earn one.</p>}
        {free.codes.length > 0 && (
          <ul className="rw-list" aria-label="Your free-day codes" data-testid="my-rewards-codes">
            {free.codes.map((c) => (
              <li key={c.code} className="rw-list__row">
                <span className="rw-list__main"><code className="rw-code__value">{c.code}</code><small>{days(c.days)}{c.booking_number ? `, on ${c.booking_number}` : c.status === 'used' ? ', used' : c.valid_until ? `, until ${fmtDay(c.valid_until)}` : ''}</small></span>
                {!c.booking_number && c.status !== 'used' && c.status !== 'expired' && (
                  <span className="rw-list__actions"><CopyLink url={c.code} label="Copy" />
                    <Act ops action="my_rewards_code_cancel" payload={{ code: c.code }} label="Cancel" variant="quiet" confirm={`Cancel ${c.code}? Its ${days(c.days)} come back.`} refresh={refresh} done="Cancelled. The days are back." testId={`my-rewards-cancel-${c.code}`} /></span>)}
              </li>))}
          </ul>
        )}
        {free.lots.length > 0 && (
          <details className="rw-more"><summary>Where your free days came from</summary>
            <ul className="rw-list">{free.lots.map((l, i) => (
              <li key={i} className="rw-list__row"><span className="rw-list__main"><b>{l.source}</b><small>{days(l.days)} earned {fmtDay(l.earned_on)}, {l.left > 0 ? `${l.left} left, ends ${fmtDay(l.expires_on)}` : 'used'}</small></span></li>))}
            </ul></details>
        )}
      </section>

      {r.rules && r.rules.length > 0 && (
        <section className="pt-card stack rw-card" aria-labelledby="mr-rules">
          <h2 className="d4" id="mr-rules">The rules</h2>
          <ul className="rw-rules" data-testid="my-rewards-rules">{r.rules.map((x) => <li key={x}>{x}</li>)}</ul>
        </section>
      )}
    </div>
  );
}
