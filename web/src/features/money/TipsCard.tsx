import { money } from '@/lib/format';
import Link from '@/components/Link';
import { tipShareWords, type TipShare } from './tips';

// r48 part 2 (3053): tips for staff (their share, on My sales and My pay) and for an Admin (every tip, Admin > Money >
// Tips: CarmaCars' share is company revenue; tips are never in the owners' revenue share).
const fmt = (c: number) => money(Number(c ?? 0), { cents: true });
const day = (iso: string) => new Date(iso).toLocaleDateString('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric' });
const ROLE: Record<string, string> = { sales: 'you sold it', handover: 'you did the handover', both: 'you sold it and did the handover', override: 'set by an Admin' };

export interface MyTipsData { month_cents: number; total_cents: number; rows: Array<{ tip_id: string; booking_number: string; paid_at: string; tip_cents: number; method: string; role: string; share_cents: number }> }
export function MyTips({ t }: { t: MyTipsData | null }) {
  if (!t) return null;
  return (
    <section className="pt-card ad-card stack" aria-labelledby="my-tips-h" data-testid="my-tips">
      <div className="pt-card__head"><h2 className="d4" id="my-tips-h">My tips</h2><span className="small muted">{fmt(t.month_cents)} this month</span></div>
      <p className="small muted">Your share of the tips renters gave: half when you sold the rental, half when you did the handover, all of it when you did both. Paid with your pay.</p>
      {t.rows.length ? <ul className="small" data-testid="my-tips-list">{t.rows.map((r) => <li key={r.tip_id}>{day(r.paid_at)}, {r.booking_number}: <b>{fmt(r.share_cents)}</b> of a {fmt(r.tip_cents)} tip ({ROLE[r.role] ?? r.role})</li>)}</ul>
        : <p className="small muted">No tips in the last 90 days yet.</p>}
    </section>
  );
}

export interface TipsReportData {
  from: string; to: string; total_cents: number; company_cents: number;
  by_staff: Array<{ staff_id: string; name: string; cents: number; tips: number }>;
  rows: Array<{ tip_id: string; booking_number: string; paid_at: string; amount_cents: number; method: string; source: string; split_by_admin: boolean; split_reason: string | null; shares: TipShare[] | null }>;
}
const SOURCE: Record<string, string> = { checkout: 'at checkout', receipt: 'on the receipt', link: 'from the after-trip link', staff: 'recorded by staff' };
export function TipsReport({ r, bookingBase }: { r: TipsReportData; bookingBase: string }) {
  return (
    <section className="stack" data-testid="tips-report">
      <h1 className="d2">Tips</h1>
      <p className="small muted">From {day(r.from)}: {fmt(r.total_cents)} in tips. CarmaCars&apos; share, kept as company revenue (direct bookings, self pickups): <b data-testid="tips-company">{fmt(r.company_cents)}</b>. Tips are never part of the owners&apos; revenue share. Change one tip&apos;s split on its booking&apos;s Money tab.</p>
      <form className="row" method="get"><input type="hidden" name="tab" value="tips" />
        <label className="label" htmlFor="tips-from">From</label><input className="input" type="date" id="tips-from" name="from" defaultValue={r.from.slice(0, 10)} />
        <label className="label" htmlFor="tips-to">To</label><input className="input" type="date" id="tips-to" name="to" />
        <button className="btn btn--ghost btn--sm" type="submit">Show</button></form>
      {r.by_staff.length > 0 && <ul className="small" data-testid="tips-by-staff">{r.by_staff.map((s) => <li key={s.staff_id}>{s.name}: <b>{fmt(s.cents)}</b> from {s.tips} tip{s.tips === 1 ? '' : 's'}</li>)}</ul>}
      {r.rows.length ? <ul className="small" data-testid="tips-rows">{r.rows.map((x) => <li key={x.tip_id}>{day(x.paid_at)}, <Link prefetch={false} className="link" href={`${bookingBase}/${encodeURIComponent(x.booking_number)}?tab=money`}>{x.booking_number}</Link>: <b>{fmt(x.amount_cents)}</b> by {x.method.replace('_', '-')} {SOURCE[x.source] ?? ''}. {tipShareWords(x.shares ?? [], fmt)}{x.split_by_admin ? ` (Admin: ${x.split_reason ?? ''})` : ''}</li>)}</ul>
        : <p className="small muted">No tips in this period.</p>}
    </section>
  );
}
