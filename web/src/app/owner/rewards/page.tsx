import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { requireOwner } from '@/server/owner/data';
import { rpc } from '@/lib/db/repo';
import { CopyLink } from '@/features/portal/CopyLink';
import { QrSvg } from '@/features/referral/QrSvg';
import { RedeemKit, UpgradeAsk, UpgradeCancel } from '@/features/owner-rewards/RewardActions';
import { RewardsGame } from '@/features/rewards/RewardsGame';
import { dollars, fmtDay, headline, milestoneFill, milestoneState, pct, type OwnerRewards } from '@/features/owner-rewards/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Rewards', path: '/owner/rewards', noindex: true, description: 'Your owner rewards: discounts, your friends and family code, credits and merch kits.' });

// Rewards (release 48, migration 3262; the owner, Nov 20: "OWNER REWARDS page ... with progress, codes and history"):
// the fleet discount while the owner's car is out and a free upgrade to ask for, the friends and family code with its
// link and QR and what it earned, the credit for referring an owner, the merch kits (a button, never automatic), the
// birthday credit, priority support and early access, and every reward so far.
export default async function OwnerRewardsPage() {
  const { user } = await requireOwner('/owner/rewards');
  const r = (await rpc('owner_portal_rewards' as never, { p_by: user.id } as never, { role: 'service_role' }).catch(() => null)) as unknown as OwnerRewards | null;
  if (!r) {
    return <><PageHeader title="Rewards" /><div className="pt-empty" data-testid="or-error"><p className="d4">Your rewards did not load.</p><p className="muted">Reload the page. Nothing was changed.</p></div></>;
  }
  if (!r.on) {
    return <><PageHeader title="Rewards" /><section className="pt-card" data-testid="or-off"><p>{r.why ?? 'Owner rewards are not on for this account.'}</p></section></>;
  }
  const fleet = r.fleet!; const fr = r.friends!; const ro = r.refer_owner!; const bd = r.birthday!;
  const months = r.months ?? 0;
  const cars = fleet.cars.map((c) => ({ vehicle_id: c.vehicle_id, name: c.name }));
  return (
    <>
      <PageHeader title="Rewards" purpose={headline(r)} testId="or-head" />
      {/* r50 hotfix 2 (5151): the games inside Rewards, for CarmaCars Rewards points */}
      <RewardsGame userId={user.id} portal="owner" />
      <div className="rw-grid" data-testid="owner-rewards">
        <section className="pt-card stack rw-card" aria-labelledby="or-fleet" data-testid="or-fleet">
          <p className="pu-eyebrow">While your car is out</p>
          <h2 className="d3" id="or-fleet">{pct(fleet.bps)} off another CarmaCars car</h2>
          <p className="small">On dates your own car is on rent, in service or in a claim. You drive; not on exotic or partner cars.</p>
          {fleet.code ? <div className="rw-code"><span className="rw-code__label">Your code</span><code className="rw-code__value" data-testid="or-fleet-code">{fleet.code}</code><CopyLink url={fleet.code} label="Copy the code" done="Copied" /></div>
            : <p className="small muted">Your code is being made. Reload in a moment.</p>}
          <p className="small" data-testid="or-fleet-now">{fleet.car_down_now ? 'One of your cars is out right now, so the code works for today.' : 'Your cars are available right now. The code works on dates one of them is out.'}</p>
          <p><Link prefetch={false} className="btn btn--primary" href="/cars" data-testid="or-fleet-book">Find a car</Link></p>
          <div className="rw-sub">
            <h3 className="d4">Down for a repair we caused?</h3>
            {r.upgrade?.status === 'requested' ? <><p className="small" data-testid="or-upgrade-state">We have your request from {fmtDay(r.upgrade.created_at)}. An Admin answers here and by email.</p><UpgradeCancel id={r.upgrade.id} /></>
              : r.upgrade?.status === 'approved' && r.upgrade.code ? <p className="alert alert--ok" data-testid="or-upgrade-state"><span className="alert__title">Free upgrade approved: {r.upgrade.code}</span>
                  <span>{dollars(r.upgrade.amount_cents ?? 0)} off a rental{r.upgrade.valid_until ? ` until ${fmtDay(r.upgrade.valid_until)}` : ''}.{r.upgrade.decision_note ? ` ${r.upgrade.decision_note}` : ''}</span></p>
              : <>{r.upgrade?.status === 'declined' && <p className="small" data-testid="or-upgrade-state">About your last request: {r.upgrade.decision_note}</p>}
                  <p className="small">Ask for a free upgrade to a car in a higher class. An Admin approves it.</p><UpgradeAsk cars={cars} /></>}
          </div>
        </section>

        <section className="pt-card stack rw-card" aria-labelledby="or-ff" data-testid="or-friends">
          <p className="pu-eyebrow">Friends and family</p>
          <h2 className="d3" id="or-ff">{pct(fr.bps)} off their first rental</h2>
          <p className="small">Share your code, your link or your QR. You earn {pct(fr.kickback_bps)} of the rental charge on their first rental, on your statement.</p>
          <div className="rw-share">
            <div className="rw-share__codes">
              <div className="rw-code"><span className="rw-code__label">Code</span><code className="rw-code__value" data-testid="or-ff-code">{fr.code}</code><CopyLink url={fr.code} label="Copy the code" done="Copied" /></div>
              <div className="rw-code"><span className="rw-code__label">Link</span><code className="rw-code__value rw-code__value--link" data-testid="or-ff-link">{fr.link.replace(/^https?:\/\//, '')}</code><CopyLink url={fr.link} label="Copy the link" /></div>
            </div>
            <div className="rw-share__qr" data-testid="or-ff-qr"><QrSvg text={fr.link} label="QR code of your friends and family link" /></div>
          </div>
          <dl className="rw-stats"><div><dt>Friends who rented</dt><dd data-testid="or-ff-rentals">{fr.rentals}</dd></div><div><dt>You earned</dt><dd>{dollars(fr.earned_cents)}</dd></div></dl>
          {fr.recent.length > 0 && <ul className="rw-list" aria-label="Rentals with your code">{fr.recent.map((x) => (
            <li key={x.booking_number} className="rw-list__row"><span className="rw-list__main"><b>{x.booking_number}</b><small>{fmtDay(x.at)}{x.kickback_cents ? `, you earn ${dollars(x.kickback_cents)}` : ', your share shows when the trip is complete'}</small></span></li>))}</ul>}
        </section>

        <section className="pt-card stack rw-card" aria-labelledby="or-ms" data-testid="or-milestones">
          <p className="pu-eyebrow">Milestones</p>
          <h2 className="d3" id="or-ms">{months} {months === 1 ? 'month' : 'months'} with CarmaCars</h2>
          <ul className="rw-milestones">
            {(r.milestones ?? []).map((m) => {
              const st = milestoneState(m);
              return (
                <li key={m.kind} className="rw-milestone" data-state={st.state} data-testid={`or-ms-${m.kind}`}>
                  <div className="rw-milestone__head"><b>{m.name}</b><span className="badge badge--outline" data-testid={`or-ms-state-${m.kind}`}>{st.state === 'shipped' ? 'Shipped' : st.state === 'requested' ? 'Getting ready' : st.state === 'ready' ? 'Ready' : `At ${m.months} months`}</span></div>
                  <div className="ck-progress rw-bar" data-complete={m.reached || undefined}>
                    <div className="ck-progress__bar" role="progressbar" aria-label={`${m.name}: ${m.months} months`} aria-valuemin={0} aria-valuemax={m.months} aria-valuenow={Math.min(months, m.months)} aria-valuetext={st.line}>
                      <span className="ck-progress__fill" style={{ ['--p' as string]: String(milestoneFill(months, m)) }} /></div>
                    <p className="ck-progress__text small">{st.line}</p>
                  </div>
                  {st.state === 'ready' && r.address && <RedeemKit kind={m.kind} name={m.name} address={r.address} />}
                </li>);
            })}
          </ul>
        </section>

        <section className="pt-card stack rw-card" aria-labelledby="or-ref" data-testid="or-refer">
          <p className="pu-eyebrow">Refer an owner</p>
          <h2 className="d3" id="or-ref">{dollars(ro.cents)} credit</h2>
          <p className="small">When an owner you referred has had a car live for {ro.live_days} days, {dollars(ro.cents)} goes on your next statement.</p>
          <div className="rw-code"><span className="rw-code__label">Link</span><code className="rw-code__value rw-code__value--link" data-testid="or-refer-link">{ro.link.replace(/^https?:\/\//, '')}</code><CopyLink url={ro.link} label="Copy the link" /></div>
          {ro.referred.length > 0 ? <ul className="rw-list" aria-label="Owners you referred">{ro.referred.map((x, i) => (
            <li key={i} className="rw-list__row"><span className="rw-list__main"><b>{x.name}</b><small>{x.credited ? 'Credit added' : x.live_at ? `Car live since ${fmtDay(x.live_at)}` : 'Car not live yet'}</small></span></li>))}</ul>
            : <p className="small muted">Nobody yet. The owners you refer show here.</p>}
        </section>

        <section className="pt-card stack rw-card" aria-labelledby="or-perks" data-testid="or-perks">
          <p className="pu-eyebrow">Yours as an owner</p>
          <h2 className="d3" id="or-perks">Birthday credit and perks</h2>
          <p className="small"><b>{dollars(bd.cents)} rental credit on your birthday.</b> {bd.code ? `This year's code: ${bd.code.code}${bd.code.valid_until ? `, until ${fmtDay(bd.code.valid_until)}` : ''}.` : bd.known ? 'Your code arrives on the day.' : <>We do not have your birthday yet. Add it under <Link prefetch={false} className="link" href="/owner/account">Account</Link>.</>}</p>
          <ul className="pt-steps" aria-label="Your perks">{(r.perks ?? []).map((k) => <li key={k.name} className="is-done"><span><b>{k.name}</b><small>{k.detail}</small></span></li>)}</ul>
        </section>

        <section className="pt-card stack rw-card rw-grid__wide" aria-labelledby="or-hist" data-testid="or-history">
          <h2 className="d4" id="or-hist">Your rewards so far</h2>
          {(r.history ?? []).length > 0 ? <ul className="rw-list">{r.history!.map((x, i) => (
            <li key={i} className="rw-list__row"><span className="rw-list__main"><b>{x.title}</b><small>{fmtDay(x.at)}{x.detail ? `. ${x.detail}` : ''}</small></span>{x.amount_cents ? <span className="rw-list__amt">{dollars(x.amount_cents)}</span> : null}</li>))}</ul>
            : <div className="pt-empty"><p className="d4">Nothing yet.</p><p className="muted">Credits, kits and codes show here as you earn them.</p></div>}
          {r.rules && <details className="rw-more"><summary>The rules</summary><ul className="rw-rules">{r.rules.map((x) => <li key={x}>{x}</li>)}</ul></details>}
        </section>
      </div>
    </>
  );
}
