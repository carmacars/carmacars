import Link from '@/components/Link';
import { GetForm } from '@/components/GetForm';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, Card, Kv, PageHead, Table, Tiles, t } from '@/features/admin/ui';
import type { RewardsState } from '@/features/rewards/types';
import { holidayRule, MONTH_OPTIONS, noticeKind, pct, WEEKDAY_OPTIONS, type HolidayRule } from '@/features/rewards/occasions';
import previews from '@/generated/rewards-emails.json';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Rewards', path: '/admin/settings/rewards', noindex: true, description: 'CarmaCars Rewards: points, tiers, ways to earn, Google review claims and adjustments.' });
type R = Record<string, unknown>;
type Settings = { enabled: boolean; points_per_dollar: number; point_value_cents: number; min_redeem_points: number; code_valid_days: number; expiry_months: number; reminder_days: number; late_grace_minutes: number };
type Data = { settings: Settings; google_review_link: string | null; social_links: Record<string, string | null> | null; actions: R[]; tiers: R[];
  /** r40 (2421) */ perks?: R[]; any_car_response_hours?: number; any_car_open?: Array<{ number: string; due_at: string; late: boolean; vehicle: string }>;
  totals: { members: number; outstanding: number; earned_30d: number; redeemed_30d: number }; google_claims: R[]; recent: R[];
  matches: Array<{ id: string; name: string; email: string | null; balance: number }> | null; renter: (RewardsState & { id: string; name: string }) | null;
  /** r48 (3000): the Rewards emails and notices, each with its switch and its counts of 30 days */
  notices?: { enabled: boolean; near_tier_pct: number; near_tier_hours: number; waiting_days: number; waiting_every_days: number;
    items: Array<{ code: string; subject: string; timing: string | null; category: string; enabled: boolean; sent_30d: number; notices_30d: number }> };
  /** r48 (3001): the birthday and holiday rewards */
  occasions?: { birthday_enabled: boolean; holiday_enabled: boolean; birthday_window_days: number; birthday_notice_days: number; holiday_notice_days: number; bookings_30d: number;
    tiers: Array<{ code: string; name: string; birthday_bps: number; holiday_bps: number; enabled: boolean }>;
    holidays: Array<HolidayRule & { code: string; name: string; enabled: boolean; next: { on: string; from: string; to: string } | null } & Record<string, unknown>> } };
type Preview = { subject: string; category: string; timing: string; html: string };
const PREVIEWS = previews as Record<string, Preview>;
const KINDS: Array<[string, string]> = [['fixed', 'A date every year'], ['nth_weekday', 'The nth weekday of a month'], ['weekday_before', 'The weekday before a date'], ['easter', 'Easter Sunday, with days before or after']];
const day = (d: string) => new Intl.DateTimeFormat('en-CA', { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' }).format(new Date(d));

// Admin > Settings > Rewards (migration 0214): on by default with sensible numbers; every way to earn on or off with its
// points; the tiers; every Google review claimed (on the renter's word) with Reverse; a renter's points with Add or take off.
export default async function RewardsAdmin({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/settings/rewards'), searchParams]);
  const a = await read<Data>('rewards', { q: sp.q ?? '', renter: sp.renter ?? '' });
  const s = a.settings;
  const refresh = ['/admin/settings/rewards'];
  const pv = sp.preview ? PREVIEWS[sp.preview] : undefined;
  const reverse = (x: R) => (x.reversed || !['earn', 'adjust'].includes(String(x.kind ?? 'earn')) ? (x.reversed ? <Badge s="closed">Reversed</Badge> : null)
    : <Act action="rewards_reverse" payload={{ id: x.id }} label="Reverse" variant="quiet" refresh={refresh} done="Reversed." testId={`rw-reverse-${String(x.id).slice(0, 8)}`}
        fields={[{ name: 'reason', label: 'Reason (the renter sees it)', type: 'text', required: true, placeholder: 'For example: referral fraud' }]} />);
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/settings">Settings</Link>} title="Rewards"
      purpose="Points on every rental and for referrals, follows and reviews, off the rental charge only. On by default." />
    <Tiles items={[{ k: 'Members', v: a.totals.members }, { k: 'Points outstanding', v: Number(a.totals.outstanding).toLocaleString('en-CA'), sub: $(Math.floor(Number(a.totals.outstanding) * s.point_value_cents)) },
      { k: 'Earned, 30 days', v: Number(a.totals.earned_30d).toLocaleString('en-CA') }, { k: 'Redeemed, 30 days', v: Number(a.totals.redeemed_30d).toLocaleString('en-CA') }]} />
    <Card title="The program" testId="rw-settings" aside={s.enabled ? <Badge s="published">On</Badge> : <Badge s="draft">Off</Badge>}>
      <Kv rows={[['Points per dollar of rental charge', String(s.points_per_dollar)], ['A point is worth', `${s.point_value_cents} cent`], ['Redeem from', `${s.min_redeem_points} points`],
        ['A code is valid', `${s.code_valid_days} days`], ['Points end after', `${s.expiry_months} months with no rental or redemption (reminder ${s.reminder_days} days before)`],
        ['On time means within', `${s.late_grace_minutes} minutes of the return time`], ['Google review page', a.google_review_link ?? 'Not set: the Google review way to earn is hidden']]} />
      <Act action="rewards_settings_save" label="Change" variant="primary" refresh={refresh} done="Saved." testId="rw-settings-save"
        fields={[{ name: 'enabled', label: 'Rewards on', type: 'bool', value: s.enabled }, { name: 'points_per_dollar', label: 'Points per dollar', type: 'number', value: s.points_per_dollar, min: 0, max: 100 },
          { name: 'point_value_cents', label: 'Value of a point, in cents', type: 'number', value: s.point_value_cents, min: 0.001, max: 100 },
          { name: 'min_redeem_points', label: 'Redeem from (points)', type: 'number', value: s.min_redeem_points, min: 1 }, { name: 'code_valid_days', label: 'Code valid (days)', type: 'number', value: s.code_valid_days, min: 7, max: 730 },
          { name: 'expiry_months', label: 'Points end after (months)', type: 'number', value: s.expiry_months, min: 1, max: 120 }, { name: 'reminder_days', label: 'Reminder (days before)', type: 'number', value: s.reminder_days, min: 1, max: 180 },
          { name: 'late_grace_minutes', label: 'On-time margin (minutes)', type: 'number', value: s.late_grace_minutes, min: 0, max: 1440 },
          { name: 'google_review_link', label: 'Google review page (https://...)', type: 'text', value: a.google_review_link ?? '', wide: true }]} />
    </Card>
    <Card title="Ways to earn" testId="rw-actions">
      <Table<R> rows={a.actions} rowKey={(x) => String(x.code)} cols={[{ key: 'label', label: 'Way to earn' }, { key: 'points', label: 'Points', num: true, render: (x) => (x.code === 'rental' ? `${x.points} a dollar` : String(x.points)) },
        { key: 'limit_text', label: 'Limit' }, { key: 'enabled', label: 'On', render: (x) => (x.enabled ? <Badge s="published">On</Badge> : <Badge s="draft">Off</Badge>) },
        { key: 'act', label: '', render: (x) => <Act action="rewards_action_save" payload={{ code: x.code }} label="Change" refresh={refresh} done="Saved." testId={`rw-action-${x.code}`}
          fields={[{ name: 'enabled', label: 'On', type: 'bool', value: x.enabled }, { name: 'points', label: x.code === 'rental' ? 'Points a dollar' : 'Points', type: 'number', value: x.points, min: 0, max: 100000 },
            { name: 'limit_text', label: 'Limit, as renters read it', type: 'text', value: x.limit_text }]} /> }]} />
      <p className="small muted">Follows are granted on the click from the Rewards page (a follow cannot be checked); a platform shows only with its page in Settings &gt; Site (social links). Google reviews are on the renter&apos;s word and listed below.</p>
    </Card>
    <Card title="Tiers" testId="rw-tiers">
      <Table<R> rows={a.tiers} rowKey={(x) => String(x.code)} cols={[{ key: 'name', label: 'Tier' }, { key: 'min_points', label: 'Points earned in 12 months', num: true, render: (x) => Number(x.min_points ?? 0).toLocaleString('en-CA') },
        { key: 'act', label: '', render: (x) => <Act action="rewards_tier_save" payload={{ code: x.code }} label="Change" refresh={refresh} done="Saved." testId={`rw-tier-${x.code}`}
          fields={[{ name: 'name', label: 'Name', type: 'text', value: x.name }, { name: 'min_points', label: 'From points earned in 12 months', type: 'number', value: x.min_points, min: 1 }]} /> }]} />
      <p className="small muted">Points earned count, not the balance: using points never lowers a tier. Below the first tier a renter is a Member. Tiers give perks, not discounts; tier codes issued before release 40 work until they end.</p>
    </Card>
    <Card title="Perks" testId="rw-perks">
      <Table<R> rows={a.perks ?? []} rowKey={(x) => String(x.code)} empty="Perks arrive with migration 2421." cols={[{ key: 'label', label: 'Perk' },
        { key: 'tier_code', label: 'From tier', render: (x) => String(a.tiers.find((y) => y.code === x.tier_code)?.name ?? x.tier_code) },
        { key: 'detail', label: 'What renters read', className: 'wrap' }, { key: 'enabled', label: 'On', render: (x) => (x.enabled ? <Badge s="published">On</Badge> : <Badge s="draft">Off</Badge>) },
        { key: 'act', label: '', render: (x) => <Act action="rewards_perk_save" payload={{ code: x.code }} label="Change" refresh={refresh} done="Saved." testId={`rw-perk-${x.code}`}
          fields={[{ name: 'enabled', label: 'On', type: 'bool', value: x.enabled }, { name: 'tier_code', label: 'From tier', type: 'select', value: x.tier_code, options: a.tiers.map((y) => [String(y.code), String(y.name)] as [string, string]) },
            { name: 'label', label: 'Name', type: 'text', value: x.label }, { name: 'detail', label: 'What renters read', type: 'text', value: x.detail, wide: true }]} /> }]} />
      <p className="small muted">A perk belongs to one tier and every tier above keeps it. Instant Book: the request is booked at once (an Admin can still take it away from a renter). Any car, any time: a request on taken dates is a priority request for Fleet; it never cancels or moves another booking. The free day: one code a year that CarmaCars pays for, never the owner.</p>
      <Kv rows={[['Fleet answers a priority request within', `${a.any_car_response_hours ?? 4} hours`]]} />
      <Act action="rewards_settings_save" label="Change the response time" refresh={refresh} done="Saved." testId="rw-any-car-hours"
        fields={[{ name: 'any_car_response_hours', label: 'Hours to answer', type: 'number', value: a.any_car_response_hours ?? 4, min: 1, max: 72 }]} />
      {(a.any_car_open ?? []).length > 0 && <ul className="linklist" data-testid="rw-any-car-open">{(a.any_car_open ?? []).map((o) => (
        <li key={o.number}><Link prefetch={false} className="link" href={`/admin/bookings/${o.number}`}>{o.number}</Link> {o.vehicle}: answer by {t(o.due_at)} {o.late ? <Badge s="failed">Late</Badge> : null}</li>))}</ul>}
    </Card>
    {a.notices && <Card title="Emails and notices to renters" testId="rw-notices" aside={a.notices.enabled ? <Badge s="published">On</Badge> : <Badge s="draft">Off</Badge>}>
      <p className="small">Each one is an email and a notice in the renter&apos;s portal, a text only when they have no email. Marketing ones carry an unsubscribe link and never go to someone who unsubscribed.</p>
      <Table<NonNullable<Data['notices']>['items'][number]> rows={a.notices.items} rowKey={(x) => x.code} sort={false} cols={[
        { key: 'subject', label: 'Email', className: 'wrap', render: (x) => PREVIEWS[x.code]?.subject ?? x.subject },
        { key: 'timing', label: 'When', className: 'wrap' }, { key: 'category', label: 'Kind', render: (x) => noticeKind(x.category) },
        { key: 'sent_30d', label: 'Emails, 30 days', num: true }, { key: 'notices_30d', label: 'Notices, 30 days', num: true },
        { key: 'enabled', label: 'On', render: (x) => (x.enabled ? <Badge s="published">On</Badge> : <Badge s="draft">Off</Badge>) },
        { key: 'act', label: '', render: (x) => <span className="row" style={{ gap: 'var(--s-2)' }}>
          {PREVIEWS[x.code] && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`/admin/settings/rewards?preview=${x.code}#rw-preview`} data-testid={`rw-preview-${x.code}`}>Preview</Link>}
          <Act action="rewards_notice_set" payload={{ code: x.code, enabled: !x.enabled }} label={x.enabled ? 'Turn off' : 'Turn on'} variant="quiet" refresh={refresh} done="Saved." testId={`rw-notice-${x.code}`} /></span> }]} />
      <Kv rows={[['Close to the next tier', `within ${a.notices.near_tier_pct}% of it, ${a.notices.near_tier_hours} hours after the rental`],
        ['Points waiting', `${a.notices.waiting_days} days after the last rental, at most every ${a.notices.waiting_every_days} days`]]} />
      <Act action="rewards_notices_save" label="Change" refresh={refresh} done="Saved." testId="rw-notices-save"
        fields={[{ name: 'enabled', label: 'Rewards emails and notices on', type: 'bool', value: a.notices.enabled },
          { name: 'near_tier_pct', label: 'Close to the next tier: within this percent of it', type: 'number', value: a.notices.near_tier_pct, min: 1, max: 90 },
          { name: 'near_tier_hours', label: 'Hours after the rental', type: 'number', value: a.notices.near_tier_hours, min: 0, max: 720 },
          { name: 'waiting_days', label: 'Points waiting: days after the last rental', type: 'number', value: a.notices.waiting_days, min: 7, max: 365 },
          { name: 'waiting_every_days', label: 'Points waiting: at most every (days)', type: 'number', value: a.notices.waiting_every_days, min: 14, max: 365 }]} />
    </Card>}
    {pv && <Card title={`Preview: ${pv.subject}`} id="rw-preview" testId="rw-preview"
      aside={<Link prefetch={false} className="link small" href="/admin/settings/rewards">Close</Link>}>
      <p className="small muted">{noticeKind(pv.category)}. {pv.timing}. Sample values; a renter sees their own.</p>
      <iframe title={`Preview of ${pv.subject}`} srcDoc={pv.html} sandbox="" loading="lazy"
        style={{ width: '100%', minHeight: 720, border: '1px solid var(--line, #ddd)', borderRadius: 8, background: '#fff' }} />
    </Card>}
    {a.occasions && <Card title="Birthday and holiday rewards" testId="rw-occasions">
      <p className="small">A Rewards tier gets a percent off the rental charge for a pickup near the renter&apos;s birthday or on a holiday weekend. The price shows it as its own line. The bigger one applies, never both; never below the car&apos;s lowest daily price, never on insurer or Owner Bookings.</p>
      <Kv rows={[['Birthday reward', a.occasions.birthday_enabled ? `On: a pickup within ${a.occasions.birthday_window_days} days of the birthday, email ${a.occasions.birthday_notice_days} days before` : 'Off'],
        ['Holiday reward', a.occasions.holiday_enabled ? `On: a pickup on the holiday weekend, email ${a.occasions.holiday_notice_days} days before` : 'Off'],
        ['Bookings with one, 30 days', String(a.occasions.bookings_30d)]]} />
      <Act action="rewards_occasion_save" label="Change" refresh={refresh} done="Saved." testId="rw-occasions-save"
        fields={[{ name: 'birthday_enabled', label: 'Birthday reward on', type: 'bool', value: a.occasions.birthday_enabled },
          { name: 'birthday_window_days', label: 'Days either side of the birthday', type: 'number', value: a.occasions.birthday_window_days, min: 0, max: 30 },
          { name: 'birthday_notice_days', label: 'Birthday email: days before', type: 'number', value: a.occasions.birthday_notice_days, min: 1, max: 60 },
          { name: 'holiday_enabled', label: 'Holiday reward on', type: 'bool', value: a.occasions.holiday_enabled },
          { name: 'holiday_notice_days', label: 'Holiday email: days before the weekend', type: 'number', value: a.occasions.holiday_notice_days, min: 1, max: 60 }]} />
      <Table<NonNullable<Data['occasions']>['tiers'][number]> rows={a.occasions.tiers} rowKey={(x) => x.code} sort={false} testId="rw-occasion-tiers" cols={[
        { key: 'name', label: 'Tier' }, { key: 'birthday_bps', label: 'Birthday', num: true, render: (x) => pct(x.birthday_bps) },
        { key: 'holiday_bps', label: 'Holiday', num: true, render: (x) => pct(x.holiday_bps) },
        { key: 'enabled', label: 'On', render: (x) => (x.enabled ? <Badge s="published">On</Badge> : <Badge s="draft">Off</Badge>) },
        { key: 'act', label: '', render: (x) => <Act action="rewards_occasion_tier_save" payload={{ code: x.code }} label="Change" refresh={refresh} done="Saved." testId={`rw-occasion-tier-${x.code}`}
          fields={[{ name: 'enabled', label: 'On for this tier', type: 'bool', value: x.enabled }, { name: 'birthday_bps', label: 'Birthday reward', type: 'percent', value: x.birthday_bps },
            { name: 'holiday_bps', label: 'Holiday reward', type: 'percent', value: x.holiday_bps }]} /> }]} />
      <Table<NonNullable<Data['occasions']>['holidays'][number]> rows={a.occasions.holidays} rowKey={(x) => x.code} sort={false} testId="rw-holidays" cols={[
        { key: 'name', label: 'Holiday' }, { key: 'kind', label: 'Date', render: (x) => holidayRule(x) },
        { key: 'next', label: 'Next weekend', render: (x) => (x.next ? `${day(x.next.from)} to ${day(x.next.to)}` : '') },
        { key: 'enabled', label: 'On', render: (x) => (x.enabled ? <Badge s="published">On</Badge> : <Badge s="draft">Off</Badge>) },
        { key: 'act', label: '', render: (x) => <span className="row" style={{ gap: 'var(--s-2)' }}>
          <Act action="rewards_holiday_save" payload={{ code: x.code, enabled: !x.enabled }} label={x.enabled ? 'Turn off' : 'Turn on'} variant="quiet" refresh={refresh} done="Saved." testId={`rw-holiday-${x.code}`} />
          <Act action="rewards_holiday_save" payload={{ code: x.code, remove: true }} label="Remove" variant="quiet" refresh={refresh} done="Removed." testId={`rw-holiday-remove-${x.code}`} /></span> }]} />
      <Act action="rewards_holiday_save" label="Add a holiday" refresh={refresh} done="Added." testId="rw-holiday-add"
        fields={[{ name: 'name', label: 'Name', type: 'text', required: true }, { name: 'kind', label: 'Date rule', type: 'select', value: 'fixed', options: KINDS },
          { name: 'month', label: 'Month', type: 'select', value: '1', options: MONTH_OPTIONS }, { name: 'day', label: 'Day of the month (a date, or the date the weekday comes before)', type: 'number', min: 1, max: 31 },
          { name: 'isodow', label: 'Weekday (for a weekday rule)', type: 'select', value: '1', options: WEEKDAY_OPTIONS }, { name: 'nth', label: 'Which one: 1st to 5th (for the nth weekday)', type: 'number', min: 1, max: 5 },
          { name: 'offset_days', label: 'Days after (a minus for before; for Easter)', type: 'number', value: 0, min: -60, max: 60 }]} />
    </Card>}
    <Card title="Google reviews claimed" testId="rw-google">
      <Table<R> rows={a.google_claims} rowKey={(x) => String(x.id)} empty="No claims yet." cols={[{ key: 'at', label: 'When', render: (x) => t(x.at) },
        { key: 'renter', label: 'Renter', render: (x) => <Link prefetch={false} className="link" href={`/admin/settings/rewards?renter=${x.renter_id}`}>{String(x.renter)}</Link> },
        { key: 'booking_number', label: 'Booking' }, { key: 'review_name', label: 'Name on the review' }, { key: 'points', label: 'Points', num: true }, { key: 'act', label: '', render: reverse }]} />
    </Card>
    <Card title="A renter's points" testId="rw-renter">
      <GetForm action="/admin/settings/rewards" className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap', alignItems: 'flex-end' }}>
        <div className="field"><label htmlFor="rw-q">Name, email or phone</label><input id="rw-q" name="q" defaultValue={sp.q ?? ''} /></div>
        <button className="btn btn--ghost btn--sm" type="submit">Find</button>
      </GetForm>
      {a.matches && <ul className="linklist">{a.matches.length ? a.matches.map((m) => <li key={m.id}><Link prefetch={false} className="link" href={`/admin/settings/rewards?renter=${m.id}`}>{m.name}</Link> {m.email} ({m.balance} points)</li>) : <li>No renter found.</li>}</ul>}
      {a.renter && <div className="stack">
        <p><b>{a.renter.name}</b>: {a.renter.balance.toLocaleString('en-CA')} points, {a.renter.tier.name}, code {a.renter.referral_code}</p>
        <Act action="rewards_adjust" payload={{ renter: a.renter.id }} label="Add or take off points" refresh={refresh} done="Saved." testId="rw-adjust"
          fields={[{ name: 'points', label: 'Points (a minus takes off)', type: 'number', required: true }, { name: 'reason', label: 'Reason (the renter sees it)', type: 'text', required: true }]} />
      </div>}
    </Card>
    <Card title={a.renter ? 'Their history' : 'Latest points'} testId="rw-recent">
      <Table<R> rows={a.recent} rowKey={(x) => String(x.id)} empty="Nothing yet." cols={[{ key: 'at', label: 'When', render: (x) => t(x.at) }, { key: 'renter', label: 'Renter' },
        { key: 'points', label: 'Points', num: true }, { key: 'reason', label: 'Reason', className: 'wrap' }, { key: 'act', label: '', render: reverse }]} />
    </Card>
  </>);
}
