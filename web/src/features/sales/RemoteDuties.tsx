import type { ReactNode } from 'react';
import { Act } from '@/features/admin/Act';
import { pctBps } from '@/features/sales/Commissions';
import { AvailabilityForm } from '@/features/sales/AvailabilityForm';

// Sales work modes (migration 0174): in person and remote share the Sales dashboard. A remote rep also has the day's
// lead-generation checklist, the month's touches against the minimum, the peak-hour cover of the week and the reply time on
// what is assigned to them during their blocks. The same card is read-only on Admin > Staff > Sales.
export type SalesMode = 'in_person' | 'remote';
export const MODE_LABEL: Record<SalesMode, string> = { in_person: 'In person', remote: 'Remote' };

export interface SalesProgress {
  mode: SalesMode; days: number; rate_bps: number; tier_bps: number; projected_bps: number; touches: number; min_touches: number;
  below_minimum: boolean; drop_tiers: number; dropped: boolean; closed: boolean; locked: boolean; touches_pct: number | null;
  tiers: Array<{ from_days: number; bps: number }>; label: string;
}
export interface WeekBlocks {
  start: string; end: string; label: string; peak_hours: number; hours: number;
  blocks: Array<{ id: string; day: string; day_label: string; from: string; to: string; peak_minutes: number }>;
}
export interface Replies { target_minutes: number; count: number; replied: number; within: number; late_open: number; median_minutes: number | null; within_pct: number | null }
export interface Touch { id: string; at: string; kind: string; kind_label: string; source: string; link: string | null; note: string | null; booking_number: string | null; voided: boolean; void_reason: string | null }
export interface SalesDuties {
  mode: SalesMode | null; today?: string; progress?: SalesProgress;
  settings?: { min_touches: number; drop_tiers: number; floor_bps: number; cover_hours: number; reply_minutes: number; peak_from: string; peak_until: string };
  touches_month?: number; touches_today?: Record<string, number>;
  checklist?: Array<{ key: string; label: string; count: number; open_quotes?: number }>;
  week?: WeekBlocks; next_week?: WeekBlocks; replies_week?: Replies; replies_month?: Replies; touches?: Touch[];
}

export const TOUCH_KINDS: Array<[string, string]> = [['follow_up', 'Follow-up'], ['repost', 'Repost (Marketplace, classified site)'], ['dm_reply', 'Social media DM reply'],
  ['outreach_call', 'Outreach call'], ['outreach_email', 'Outreach email'], ['outreach_text', 'Outreach text'], ['owner_outreach', 'Car owner outreach']];
const SOURCE: Record<string, string> = { manual: 'logged by hand', offer: 'offer sent', message: 'message sent', chat: 'live chat', phone: 'phone line', ad_posting: 'ad posted',
  recruit_call: 'owner call', recruit_message: 'owner message' };

const when = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));
const dropWords = (n: number) => (n === 1 ? 'one tier' : `${n} tiers`);

function Bar({ value, max, label, testId }: { value: number; max: number; label: string; testId?: string }) {
  const pct = max > 0 ? Math.min(100, Math.round((100 * value) / max)) : 100;
  return (
    <div role="progressbar" aria-label={label} aria-valuemin={0} aria-valuemax={max} aria-valuenow={Math.min(value, max)} className="va-duty-bar" data-testid={testId}>
      <span style={{ width: `${pct}%` }} />
    </div>
  );
}

/** The rate line for either mode: the tier now, and for remote what the month ends at under the minimum. */
export function ModeRate({ p, own }: { p: SalesProgress; own: boolean }) {
  const you = own ? 'You' : 'They';
  if (p.mode !== 'remote') return <p className="small" data-testid="sales-mode-rate"><b>In person.</b> {you} earn {pctBps(p.rate_bps)} this month ({p.days} rental days). Tiers {p.tiers.map((x) => pctBps(x.bps)).join(', ')}.</p>;
  return (
    <p className="small" data-testid="sales-mode-rate"><b>Remote.</b> {p.days} rental days: {pctBps(p.tier_bps)}.{' '}
      {p.drop_tiers > 0 && (p.dropped ? <span className="va-warn">Under {p.min_touches} touches: the month&apos;s rate is {dropWords(p.drop_tiers)} lower, {pctBps(p.rate_bps)}.</span>
        : p.below_minimum ? <>If the month ended now ({p.touches} of {p.min_touches} touches) the rate would drop {dropWords(p.drop_tiers)} to <b>{pctBps(p.projected_bps)}</b>.</>
          : <>Minimum of {p.min_touches} touches met.</>)}
    </p>
  );
}

export function RemoteDuties({ d, own, touchAction }: { d: SalesDuties; own: boolean; touchAction?: (t: Touch) => ReactNode }) {
  if (d.mode !== 'remote' || !d.progress || !d.settings) return null;
  const p = d.progress;
  const s = d.settings;
  const rw = d.replies_week!;
  const rm = d.replies_month!;
  const week = d.week!;
  return (
    <section className="va-section pu-panel sd-card" aria-labelledby="va-remote-h" data-testid="remote-duties">
      <div className="va-section__head"><h2 className="va-section__title" id="va-remote-h">Remote duties</h2>
        <p className="va-section__note">Peak hours: Thursday to Sunday, {s.peak_from} to {s.peak_until} Toronto time</p></div>
      <ModeRate p={p} own={own} />

      <div className="stack" data-testid="remote-touches">
        <p className="small"><b>{d.touches_month} of {s.min_touches} touches this month.</b> {s.drop_tiers > 0 ? `Under ${s.min_touches} when the month ends, its rate is ${dropWords(s.drop_tiers)} lower.` : 'No minimum this month.'}</p>
        <Bar value={d.touches_month ?? 0} max={s.min_touches} label={`Touches this month: ${d.touches_month} of ${s.min_touches}`} testId="remote-touches-bar" />
      </div>

      <h3 className="va-duty-h">Today&apos;s checklist</h3>
      <ul className="va-checklist" data-testid="remote-checklist">
        {d.checklist!.map((c) => {
          const done = c.key === 'follow_up' ? (c.open_quotes ?? 0) === 0 || c.count >= 3 : c.count > 0;
          return (
            <li key={c.key} className={done ? 'is-done' : undefined} data-testid={`checklist-${c.key}`}>
              <span className="va-checklist__mark" aria-hidden="true">{done ? '✓' : ''}</span>
              <span className="va-checklist__text"><b>{c.label}</b>
                <span className="small muted">{c.key === 'follow_up' ? `${c.count} today; ${c.open_quotes ?? 0} open ${c.open_quotes === 1 ? 'deal has' : 'deals have'} fewer than three follow-ups` : `${c.count} today`}</span></span>
              <span className="vh">{done ? 'done' : 'to do'}</span>
            </li>);
        })}
      </ul>
      {own && <Act action="sales_touch_log" label="Log a touch" testId="log-touch" refresh={['/staff', '/staff/my-sales']} done="Logged."
        fields={[{ name: 'kind', label: 'Type', type: 'select', options: TOUCH_KINDS, required: true }, { name: 'link', label: 'Link (optional: the post, the profile, the listing)', type: 'text', placeholder: 'https://' },
          { name: 'booking', label: 'Booking number (optional)', type: 'text' }, { name: 'note', label: 'Note (optional)', type: 'text' }]} />}

      <h3 className="va-duty-h">Cover and reply time</h3>
      <ul className="sd-rows" data-testid="remote-cover">
        <li><span>Peak hours scheduled, {week.label.toLowerCase()}</span><span className={week.peak_hours < s.cover_hours ? 'va-warn' : undefined}>{week.peak_hours} of {s.cover_hours} hours</span></li>
        <li><span>Replies within {rw.target_minutes} minutes this week</span><span>{rw.count ? `${rw.within} of ${rw.count}` : 'none assigned yet'}</span></li>
        <li><span>Median reply this month</span><span>{rm.median_minutes !== null && rm.median_minutes !== undefined ? `${rm.median_minutes} min` : 'none yet'}{rm.late_open ? `, ${rm.late_open} late and open` : ''}</span></li>
      </ul>
      <p className="small muted">The reply time counts chats, texts, calls and requests assigned to {own ? 'you' : 'them'} during {own ? 'your' : 'their'} blocks. A website request {own ? 'you answer' : 'they answer'} with the first offer during a block is credited as sourced. Walk-ins and partner deals earn remote staff no commission.</p>

      {own ? <AvailabilityForm week={week} next={d.next_week!} today={d.today!} />
        : <ul className="sd-rows" data-testid="remote-blocks">{[...week.blocks, ...d.next_week!.blocks].map((b) => <li key={b.id}><span>{b.day_label}</span><span>{b.from} to {b.to}</span></li>)}
          {week.blocks.length + d.next_week!.blocks.length === 0 && <li><span>No blocks this week or next</span><span /></li>}</ul>}

      <details data-testid="remote-touch-list"><summary className="link">Touches this month ({d.touches!.length > 39 ? 'latest 40' : d.touches!.length})</summary>
        <ul className="sd-rows">{d.touches!.map((t) => (
          <li key={t.id}><span>{when(t.at)} · {t.kind_label} <span className="muted">({SOURCE[t.source] ?? t.source}){t.booking_number ? ` ${t.booking_number}` : ''}</span>
            {t.link ? <> <a className="link" href={t.link} rel="noopener noreferrer nofollow" target="_blank">link</a></> : null}{t.voided ? <span className="ad-sub">Voided: {t.void_reason}</span> : null}</span>
            <span>{touchAction && !t.voided ? touchAction(t) : null}</span></li>))}</ul>
      </details>
    </section>
  );
}
