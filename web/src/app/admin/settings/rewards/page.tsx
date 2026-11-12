import Link from '@/components/Link';
import { GetForm } from '@/components/GetForm';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, Card, Kv, PageHead, Table, Tiles, t } from '@/features/admin/ui';
import type { RewardsState } from '@/features/rewards/types';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Rewards', path: '/admin/settings/rewards', noindex: true, description: 'CarmaCars Rewards: points, tiers, ways to earn, Google review claims and adjustments.' });
type R = Record<string, unknown>;
type Settings = { enabled: boolean; points_per_dollar: number; point_value_cents: number; min_redeem_points: number; code_valid_days: number; expiry_months: number; reminder_days: number; late_grace_minutes: number };
type Data = { settings: Settings; google_review_link: string | null; social_links: Record<string, string | null> | null; actions: R[]; tiers: R[];
  /** r40 (2421) */ perks?: R[]; any_car_response_hours?: number; any_car_open?: Array<{ number: string; due_at: string; late: boolean; vehicle: string }>;
  totals: { members: number; outstanding: number; earned_30d: number; redeemed_30d: number }; google_claims: R[]; recent: R[];
  matches: Array<{ id: string; name: string; email: string | null; balance: number }> | null; renter: (RewardsState & { id: string; name: string }) | null };

// Admin > Settings > Rewards (migration 0214): on by default with sensible numbers; every way to earn on or off with its
// points; the tiers; every Google review claimed (on the renter's word) with Reverse; a renter's points with Add or take off.
export default async function RewardsAdmin({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/settings/rewards'), searchParams]);
  const a = await read<Data>('rewards', { q: sp.q ?? '', renter: sp.renter ?? '' });
  const s = a.settings;
  const refresh = ['/admin/settings/rewards'];
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
