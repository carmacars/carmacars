import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { pct } from '@/lib/format';
import { page } from '@/server/admin/api';
import { $, ago, BookingLink, Card, PageHead, t, Tiles, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Today', path: '/admin', noindex: true, description: 'What needs an Admin now.' });

type Dash = {
  now: string; target_minutes: number;
  pickups: Array<{ booking_number: string; at: string; vehicle: string; plate: string; renter: string; missing: string[] | null; staff: string | null }>;
  returns: Array<{ booking_number: string; at: string; vehicle: string; plate: string; renter: string; status: string }>;
  requests: Array<{ booking_number: string; vehicle: string; renter: string; waiting_minutes: number; awaiting_renter: boolean; pickup_at: string }>;
  offers: Array<{ booking_number: string; vehicle: string; renter: string; status: string; expires_at: string | null }>;
  payments_failed: Array<{ id: string; amount_cents: number; purpose: string; booking_number: string | null; owner: string | null; decline: string | null; at: string }>;
  deposits_due: Array<{ kind: string; booking_number: string; amount_cents: number; due: string }>;
  late: Array<{ booking_number: string; vehicle: string; renter: string; minutes_late: number }>;
  tasks: Array<{ queue: string; open: number; overdue: number; escalated: number }>;
  escalations: Array<{ id: string; title: string; reason: string; booking_number: string | null }>;
  fleet: { by_status: Record<string, number>; fleet_policy: number; min_fleet: number; days_in_program: number; days_rented: number; utilization_bps: number };
  cash: { in_cents: number; refunds_cents: number; payouts_cents: number; expenses_cents: number; deposits_held_cents: number };
  approvals: Record<string, number>;
  alerts: Array<{ field: string; message: string; blocks?: string | null }>;
  email_today: number; email_cap: number;
};

// The dashboard (03-admin.md section 1): needs you, today, money and fleet. Every card has its own zero state.
export default async function AdminToday() {
  const { read } = await page('/admin');
  const d = await read<Dash>('dashboard');
  const over = d.requests.filter((r) => !r.awaiting_renter && r.waiting_minutes > d.target_minutes).length;
  return (
    <>
      <PageHead title="Today" kicker={t(d.now)}><Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/requests">Work the requests</Link><Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/calendar">Calendar</Link></PageHead>
      {d.alerts.length > 0 && (
        <Card title="Alerts" tone="warn" testId="dash-alerts">
          <ul className="ad-list">{d.alerts.map((a, i) => <li key={i}><span>{a.message}{a.blocks ? <span className="muted"> (blocks {label(a.blocks)})</span> : null}</span>{a.field !== 'job' && <Link prefetch={false} className="link small" href="/admin/settings/site">Fix in settings</Link>}</li>)}</ul>
        </Card>
      )}
      <Tiles items={[
        { k: 'Requests waiting', v: d.requests.length, sub: over ? `${over} past the ${d.target_minutes / 60}-hour target` : `target ${d.target_minutes / 60} hours`, href: '/admin/requests', warn: over > 0 },
        { k: 'Offers out', v: d.offers.length, href: '/admin/requests?state=offer_out' },
        { k: 'Late returns', v: d.late.length, warn: d.late.length > 0, href: '/admin/bookings?status=on_rent' },
        { k: 'Payments failed', v: d.payments_failed.length, warn: d.payments_failed.length > 0, href: '/admin/money?status=failed' },
        { k: 'Utilization this month', v: pct(d.fleet.utilization_bps), sub: `${Number(d.fleet.days_rented).toFixed(0)} of ${Number(d.fleet.days_in_program).toFixed(0)} car days`, href: '/admin/reports' },
        { k: 'Fleet policy', v: `${d.fleet.fleet_policy} / ${d.fleet.min_fleet}`, warn: d.fleet.fleet_policy < d.fleet.min_fleet, href: '/admin/vehicles' }
      ]} />
      <div className="ad-cols ad-cols--3">
        <div className="stack">
          <Card title="Requests waiting" testId="dash-requests" aside={<span className="small muted">target {d.target_minutes} min</span>}>
            {d.requests.length ? <ul className="ad-list">{d.requests.slice(0, 8).map((r) => (
              <li key={r.booking_number}><span><BookingLink n={r.booking_number} /> {r.renter}</span>
                <span className={!r.awaiting_renter && r.waiting_minutes > d.target_minutes ? 'ad-late' : 'small'}>{r.awaiting_renter ? 'waiting on renter' : ago(r.waiting_minutes)}</span>
                <span className="ad-sub">{r.vehicle} · pickup {t(r.pickup_at)}</span></li>))}</ul> : <p className="small muted">Nothing waiting.</p>}
          </Card>
          <Card title="Offers awaiting renters">
            {d.offers.length ? <ul className="ad-list">{d.offers.map((r) => <li key={r.booking_number}><span><BookingLink n={r.booking_number} /> {r.renter}</span><span className="small">{r.status === 'pending_payment' ? 'signing and payment' : r.expires_at ? `until ${t(r.expires_at)}` : ''}</span></li>)}</ul> : <p className="small muted">No offers out.</p>}
          </Card>
          <Card title="Escalations">
            {d.escalations.length ? <ul className="ad-list">{d.escalations.map((e) => <li key={e.id}><span>{e.title}</span>{e.booking_number ? <BookingLink n={e.booking_number} /> : <Link prefetch={false} className="link small" href="/admin/tasks">Tasks</Link>}<span className="ad-sub">{e.reason}</span></li>)}</ul> : <p className="small muted">Nothing escalated.</p>}
          </Card>
        </div>
        <div className="stack">
          <Card title="Pickups today" testId="dash-pickups">
            {d.pickups.length ? <ul className="ad-list">{d.pickups.map((r) => (
              <li key={r.booking_number}><span>{t(r.at).split(', ').pop()} <BookingLink n={r.booking_number} /> {r.renter}</span><span className="small">{r.staff ?? 'no driver'}</span>
                <span className="ad-sub">{r.vehicle} {r.plate} · {r.missing?.length ? `missing: ${r.missing.map(label).join(', ')}` : 'ready'}</span></li>))}</ul> : <p className="small muted">No pickups today.</p>}
          </Card>
          <Card title="Returns today">
            {d.returns.length ? <ul className="ad-list">{d.returns.map((r) => <li key={r.booking_number}><span>{t(r.at).split(', ').pop()} <BookingLink n={r.booking_number} /> {r.renter}</span><span className="small">{r.vehicle}</span></li>)}</ul> : <p className="small muted">No returns today.</p>}
          </Card>
          <Card title="Late now" tone={d.late.length ? 'warn' : undefined}>
            {d.late.length ? <ul className="ad-list">{d.late.map((r) => <li key={r.booking_number}><span><BookingLink n={r.booking_number} /> {r.renter}</span><span className="ad-late">{ago(r.minutes_late)} late</span></li>)}</ul> : <p className="small muted">No car is late.</p>}
          </Card>
          <Card title="Tasks by queue">
            {d.tasks.length ? <ul className="ad-list">{d.tasks.map((q) => <li key={q.queue}><Link prefetch={false} className="link" href={`/admin/tasks?queue=${q.queue}`}>{label(q.queue)}</Link><span className="small">{q.open} open{q.overdue ? `, ${q.overdue} overdue` : ''}{q.escalated ? `, ${q.escalated} escalated` : ''}</span></li>)}</ul> : <p className="small muted">No open tasks.</p>}
          </Card>
        </div>
        <div className="stack">
          <Card title="Money this month">
            <ul className="ad-list">
              <li><span>Cash in</span><b>{$(d.cash.in_cents)}</b></li>
              <li><span>Refunds out</span><span>{$(d.cash.refunds_cents)}</span></li>
              <li><span>Payouts out</span><span>{$(d.cash.payouts_cents)}</span></li>
              <li><span>Expenses entered</span><span>{$(d.cash.expenses_cents)}</span></li>
              <li><span>Deposits held</span><span>{$(d.cash.deposits_held_cents)}</span></li>
            </ul>
          </Card>
          <Card title="Payments failed">
            {d.payments_failed.length ? <ul className="ad-list">{d.payments_failed.slice(0, 6).map((p) => <li key={p.id}><span>{p.booking_number ? <BookingLink n={p.booking_number} /> : p.owner} {label(p.purpose)}</span><span>{$(p.amount_cents)}</span><span className="ad-sub">{p.decline ?? 'declined'} · {t(p.at)}</span></li>)}</ul> : <p className="small muted">No failed payments.</p>}
          </Card>
          <Card title="Deposits due">
            {d.deposits_due.length ? <ul className="ad-list">{d.deposits_due.map((x, i) => <li key={i}><span><BookingLink n={x.booking_number} /> {x.kind === 'take' ? 'take before pickup' : 'release due'}</span><span>{$(x.amount_cents)}</span></li>)}</ul> : <p className="small muted">Nothing due.</p>}
          </Card>
          <Card title="Waiting for approval">
            <ul className="ad-list">
              <li><Link prefetch={false} className="link" href="/admin/money?tab=refunds">Refunds</Link><span>{d.approvals.refunds}</span></li>
              <li><Link prefetch={false} className="link" href="/admin/payouts">Payouts</Link><span>{d.approvals.payouts}</span></li>
              <li><Link prefetch={false} className="link" href="/admin/statements">Owner statements</Link><span>{d.approvals.statements}</span></li>
              <li><Link prefetch={false} className="link" href="/admin/listings">Listings</Link><span>{d.approvals.listings}</span></li>
              <li><Link prefetch={false} className="link" href="/admin/tolls">Tolls to match</Link><span>{d.approvals.tolls}</span></li>
            </ul>
            <p className="small muted">Email sent today: {d.email_today} of {d.email_cap ?? 100}.</p>
          </Card>
        </div>
      </div>
    </>
  );
}
