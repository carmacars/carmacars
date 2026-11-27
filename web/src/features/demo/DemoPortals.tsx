'use client';
import { useState } from 'react';
import { Milestones } from '@/components/portal-ui/Milestones';
import { PickupCountdown } from '@/features/portal/PickupCountdown';
import { money } from '@/lib/format';
import { DEMO_BOOKING as B, DEMO_STATEMENT as S, OWNER_STAGES, RENTER_STAGES, ownerTrack, renterTrack } from './model';
import './demo.css';

// r50 hotfix 2: the demo renter and owner portals for staff. Made-up data in the portals' own pieces (the step tracker,
// the countdown, the money card, the next step), one stage at a time, so staff see each process as the customer does.
// Every button here only says what it would do: nothing is read from or written to the database, nothing is sent.

function Banner({ who }: { who: string }) {
  return <p className="demo-banner" role="note" data-testid="demo-banner"><b>Demo {who} portal</b><span>Made-up data. Nothing you press here sends, charges or saves anything.</span></p>;
}

function Stages({ list, at, set, label, testId }: { list: Array<{ key: string; label: string }>; at: number; set: (i: number) => void; label: string; testId: string }) {
  return (
    <div className="demo-stages" role="tablist" aria-label={label} data-testid={testId}>
      {list.map((s, i) => <button key={s.key} type="button" role="tab" aria-selected={i === at} className="demo-stage" onClick={() => set(i)} data-testid={`${testId}-${s.key}`}>{i + 1}. {s.label}</button>)}
    </div>
  );
}

function Pretend({ label, onPress }: { label: string; onPress: (t: string) => void }) {
  return <button type="button" className="btn btn--ghost btn--sm" onClick={() => onPress(`Demo: "${label}" would open here. Nothing was sent or saved.`)}>{label}</button>;
}

export function DemoRenter() {
  const [at, setAt] = useState(3);
  const [said, setSaid] = useState<string | null>(null);
  // the demo's clock: the moment the page opened (a fixed pickup to count down to)
  const [opened] = useState(() => new Date().getTime());
  const st = RENTER_STAGES[at]!;
  const total = B.rentalCents + B.feesCents + B.hstCents;
  const paid = ['confirmed', 'on_rent', 'returned', 'closed'].includes(st.status);
  const pickupAt = new Date(opened + (st.key === 'pickup' ? 3 * 3600e3 : 3 * 86400e3)).toISOString();
  return (
    <div className="stack demo" data-testid="demo-renter" data-stage={st.key}>
      <Banner who="renter" />
      <Stages list={RENTER_STAGES} at={at} set={(i) => { setAt(i); setSaid(null); }} label="The booking's stages" testId="demo-renter-stage" />
      <section className="pt-card stack" aria-labelledby="demo-r-h">
        <div className="demo-hero">
          <div><p className="pu-eyebrow">{B.number}</p><h2 className="d3" id="demo-r-h">{B.car}</h2><p className="small muted">{B.colour}, {B.days} days</p></div>
          <span className="badge" data-testid="demo-renter-status">{st.badge}</span>
        </div>
        <div className="demo-next"><p className="pu-eyebrow">Do this next</p><p className="d4">{st.next.title}</p><p className="small">{st.next.note}</p>
          <Pretend label={st.next.cta} onPress={setSaid} /></div>
        {said && <p className="alert" role="status" data-testid="demo-said"><span>{said}</span></p>}
      </section>
      {['offered', 'sign', 'confirmed', 'pickup'].includes(st.key) && <PickupCountdown key={st.key} until={pickupAt} initialMs={new Date(pickupAt).getTime() - opened} place={B.place} testId="demo-countdown" />}
      <section className="pt-card stack" aria-label="Steps">
        <Milestones key={st.key} steps={renterTrack(at)} storageKey={`demo-renter-${st.key}`} testId="demo-renter-steps" label={`Steps for booking ${B.number}`} finish="Trip complete" celebrate={false} />
      </section>
      <div className="pt-split">
        <section className="pt-card stack" aria-labelledby="demo-r-money">
          <h2 className="d4" id="demo-r-money">Money</h2>
          <dl className="pt-dl pt-dl--money">
            <div><dt>Rental, {B.days} days</dt><dd className="num">{money(B.rentalCents, { cents: true })}</dd></div>
            <div><dt>Fees</dt><dd className="num">{money(B.feesCents, { cents: true })}</dd></div>
            <div><dt>HST</dt><dd className="num">{money(B.hstCents, { cents: true })}</dd></div>
            <div><dt><b>{paid ? 'Paid' : 'Due at booking'}</b></dt><dd className="num"><b>{money(total, { cents: true })}</b></dd></div>
            <div><dt>Deposit (a hold, released after the return)</dt><dd className="num">{money(B.depositCents, { cents: true })}</dd></div>
          </dl>
        </section>
        <section className="pt-card stack" aria-labelledby="demo-r-notices">
          <h2 className="d4" id="demo-r-notices">What the renter gets at this stage</h2>
          <ul className="small demo-list" data-testid="demo-renter-notices">{st.notices.map((n) => <li key={n}>{n}</li>)}</ul>
          <div className="row"><Pretend label="Message us" onPress={setSaid} /><Pretend label="Add a driver" onPress={setSaid} /><Pretend label="Documents" onPress={setSaid} /></div>
        </section>
      </div>
    </div>
  );
}

export function DemoOwner() {
  const [at, setAt] = useState(3);
  const [said, setSaid] = useState<string | null>(null);
  const stages = [...OWNER_STAGES.map((s) => ({ key: s.key, label: s.label })), { key: 'earning', label: 'Earning' }];
  const cur = OWNER_STAGES[at];
  return (
    <div className="stack demo" data-testid="demo-owner" data-stage={stages[at]!.key}>
      <Banner who="owner" />
      <Stages list={stages} at={at} set={(i) => { setAt(i); setSaid(null); }} label="The owner's steps" testId="demo-owner-stage" />
      <section className="pt-card stack" aria-labelledby="demo-o-h">
        <div className="demo-hero">
          <div><p className="pu-eyebrow">Owner: Sam Example</p><h2 className="d3" id="demo-o-h">2023 Tesla Model 3</h2><p className="small muted">Managed plan</p></div>
          <span className="badge" data-testid="demo-owner-status">{cur ? cur.label : 'Live'}</span>
        </div>
        {cur ? <div className="demo-next"><p className="pu-eyebrow">{['registration', 'fleet_policy'].includes(cur.key) ? 'With CarmaCars' : 'Your turn'}</p><p className="d4">{cur.label}</p>
            <p className="small">{cur.owner}</p><p className="small muted">Staff: {cur.staff} Expected: {cur.expected}.</p><Pretend label="Do it now" onPress={setSaid} /></div>
          : <div className="demo-next"><p className="pu-eyebrow">This month</p><p className="d4">{S.days} days rented, {S.occupancy}% of the month</p><p className="small">Your payout lands on the 15th.</p><Pretend label="See the statement" onPress={setSaid} /></div>}
        {said && <p className="alert" role="status" data-testid="demo-said"><span>{said}</span></p>}
      </section>
      <section className="pt-card stack" aria-label="Onboarding steps">
        <Milestones key={at} steps={ownerTrack(at)} storageKey={`demo-owner-${at}`} testId="demo-owner-steps" label="Onboarding steps of the 2023 Tesla Model 3" finish="Listed and earning" celebrate={false} />
      </section>
      {!cur && <section className="pt-card stack" aria-labelledby="demo-o-st" data-testid="demo-owner-statement">
        <h2 className="d4" id="demo-o-st">{S.month} statement</h2>
        <dl className="pt-dl pt-dl--money">
          <div><dt>Rental revenue</dt><dd className="num">{money(S.grossCents, { cents: true })}</dd></div>
          <div><dt>CarmaCars share (30%)</dt><dd className="num">-{money(S.shareCents, { cents: true })}</dd></div>
          <div><dt>Insurance</dt><dd className="num">-{money(S.insuranceCents, { cents: true })}</dd></div>
          <div><dt>Tracker</dt><dd className="num">-{money(S.trackerCents, { cents: true })}</dd></div>
          <div><dt><b>Your payout</b></dt><dd className="num"><b>{money(S.payoutCents, { cents: true })}</b></dd></div>
        </dl>
      </section>}
    </div>
  );
}
