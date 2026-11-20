import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, Card, Kv, PageHead, Table, Tiles } from '@/features/admin/ui';
import { NotificationPrefs } from '@/features/notifications/NotificationPrefs';
import { saveNotifyPrefFor } from '@/server/actions/notify-prefs';
import type { Portal, PrefState } from '@/features/notifications/prefs';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Notification preferences', path: '/admin/settings/notifications', noindex: true, description: 'The kinds of notification people can switch, their defaults, each person\'s choices and the owner tracker alerts.' });

type R = Record<string, unknown>;
type Data = {
  types: Array<{ code: string; label: string; detail: string | null; grp: string; portals: Portal[]; locked: boolean; channels: string[]; push_default: boolean; email_default: boolean; text_default: boolean; live: boolean; codes: number; changed_by: number }>;
  people: Array<{ user_id: string; name: string; email: string | null; portals: Portal[]; changed: number; cadence: string; quiet_on: boolean; all_off: boolean }>;
  person: (PrefState & { user_id: string; name: string }) | null; waiting: number };
type Places = { live: boolean; trackers_available: boolean; speed_kmh: number; sent_30d: number;
  places: Array<{ id: string; kind: string; name: string; latitude: number; longitude: number; radius_m: number; is_active: boolean; note: string | null }> };
const yes = (v: boolean) => (v ? 'On' : 'Off');
const PORTAL: Record<string, string> = { renter: 'Renters', owner: 'Owners', investor: 'Investors', staff: 'Staff', admin: 'Admins', partner: 'Partners' };
const KIND: Record<string, string> = { impound: 'Impound lot', auto_shop: 'Auto shop', port: 'Shipping port' };

// Admin > Settings > Notification preferences (release 48, migrations 3260 and 3264). Everyone chooses their own on their
// portal's Notifications page; here: the kinds of notification and what each starts as (the locked ones are always sent),
// who changed something (open a person to see or change theirs, logged with your name), and the owner's tracker alerts
// with the places watched.
export default async function NotifyAdmin({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/settings/notifications'), searchParams]);
  const user = sp.user && /^[0-9a-f-]{36}$/.test(sp.user) ? sp.user : '';
  const [a, tp] = await Promise.all([read<Data>('notify_prefs', { user, portal: sp.portal ?? '' }), read<Places>('tracker_places').catch(() => null)]);
  const refresh = ['/admin/settings/notifications'];
  const optional = a.types.filter((t) => !t.locked);
  const locked = a.types.filter((t) => t.locked);
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/settings">Settings</Link>} title="Notification preferences"
      purpose="Everyone chooses what they get by push, email and text on their own Notifications page. Here: what each kind starts as, and each person's choices." />
    <Tiles items={[{ k: 'Kinds people can switch', v: optional.length }, { k: 'Always sent', v: locked.length }, { k: 'People who changed something', v: a.people.length },
      { k: 'Lines waiting for a summary', v: a.waiting }]} />

    {a.person && (
      <Card title={`${a.person.name}: their choices`} testId="np-person" tone="next"
        aside={<Link prefetch={false} className="link small" href="/admin/settings/notifications">Close</Link>}>
        <p className="small muted">A change here is saved at once and logged with your name. The person sees it on their own page.</p>
        {a.person.portals.length > 1 && <p className="ad-filters" aria-label="Portal">{a.person.portals.map((p) => (
          <Link prefetch={false} key={p} href={`/admin/settings/notifications?user=${a.person!.user_id}&portal=${p}`} aria-current={a.person!.portal === p ? 'page' : undefined}>{PORTAL[p] ?? p}</Link>))}</p>}
        <NotificationPrefs key={`${a.person.user_id}-${a.person.portal}`} initial={a.person} idp="np-for" save={saveNotifyPrefFor.bind(null, a.person.user_id, a.person.portal)} />
      </Card>
    )}

    <Card title="Kinds people can switch" testId="np-types">
      <Table<R> rows={optional as unknown as R[]} rowKey={(x) => String(x.code)} empty="No kinds yet." cols={[
        { key: 'label', label: 'Kind', className: 'wrap', render: (x) => <><b>{String(x.label)}</b>{x.live ? null : <> <Badge s="draft">Waits for trackers</Badge></>}<br /><span className="small muted">{String(x.detail ?? '')}</span></> },
        { key: 'portals', label: 'For', render: (x) => (x.portals as string[]).map((p) => PORTAL[p] ?? p).join(', ') },
        { key: 'push_default', label: 'Push', render: (x) => ((x.channels as string[]).includes('push') ? yes(Boolean(x.push_default)) : 'n/a') },
        { key: 'email_default', label: 'Email', render: (x) => ((x.channels as string[]).includes('email') ? yes(Boolean(x.email_default)) : 'n/a') },
        { key: 'text_default', label: 'Text', render: (x) => ((x.channels as string[]).includes('text') ? yes(Boolean(x.text_default)) : 'n/a') },
        { key: 'changed_by', label: 'Changed by', num: true },
        { key: 'act', label: '', render: (x) => <Act action="notify_type_save" payload={{ type: x.code }} label="Change" refresh={refresh} done="Saved." testId={`np-type-${x.code}`} title={`Starts as: ${String(x.label)}`}
          fields={[{ name: 'push_default', label: 'Push on to start with', type: 'bool', value: x.push_default }, { name: 'email_default', label: 'Email on to start with', type: 'bool', value: x.email_default },
            { name: 'text_default', label: 'Text on to start with', type: 'bool', value: x.text_default }]} /> }]} />
      <p className="small muted">What a kind starts as applies to everyone who has not chosen for themselves. A person&apos;s own choice always wins.</p>
    </Card>

    <Card title="Always sent" testId="np-locked">
      <Table<R> rows={locked as unknown as R[]} rowKey={(x) => String(x.code)} sort={false} cols={[
        { key: 'label', label: 'Kind', className: 'wrap', render: (x) => <><b>{String(x.label)}</b><br /><span className="small muted">{String(x.detail ?? '')}</span></> },
        { key: 'portals', label: 'For', render: (x) => (x.portals as string[]).map((p) => PORTAL[p] ?? p).join(', ') },
        { key: 'codes', label: 'Messages of this kind', num: true }]} />
      <p className="small muted">Nobody can switch these off: security and sign-in codes, legal and agreement notices, charges and fees (the record if a charge is disputed), receipts, booking confirmations and changes, pickup and return reminders, safety; for staff, the work assigned to them and onboarding or suspension notices.</p>
    </Card>

    <Card title="People who changed something" testId="np-people">
      <Table<R> rows={a.people as unknown as R[]} rowKey={(x) => String(x.user_id)} empty="Nobody has changed anything yet: everyone is on the defaults above." cols={[
        { key: 'name', label: 'Person', className: 'wrap', render: (x) => <Link prefetch={false} className="link" href={`/admin/settings/notifications?user=${String(x.user_id)}`} data-testid={`np-open-${String(x.user_id).slice(0, 8)}`}>{String(x.name)}</Link> },
        { key: 'portals', label: 'Portals', render: (x) => (x.portals as string[]).map((p) => PORTAL[p] ?? p).join(', ') },
        { key: 'changed', label: 'Kinds changed', num: true },
        { key: 'cadence', label: 'Emails', render: (x) => (x.cadence === 'instant' ? 'Instant' : x.cadence === 'daily' ? 'Daily summary' : 'Weekly summary') },
        { key: 'quiet_on', label: 'Quiet hours', render: (x) => yes(Boolean(x.quiet_on)) },
        { key: 'all_off', label: 'Everything optional', render: (x) => (x.all_off ? <Badge s="closed">Off</Badge> : 'On') }]} />
    </Card>

    {tp && (
      <Card title="Owner tracker alerts" testId="np-tracker" aside={tp.live ? <Badge s="published">Live</Badge> : <Badge s="draft">Waiting for trackers</Badge>}>
        <Kv rows={[['Trackers available', tp.trackers_available ? 'Yes' : 'No: the alerts start when Trackers available is switched on in Program settings'],
          ['An owner is told about', 'A watched place, possible theft, the tracker disconnected or tampered with, a crash or impact (on to start with); a health warning, over the speed below and the weekly driving summary (off to start with)'],
          ['Speed an owner is told about', `${tp.speed_kmh} km/h`], ['Sent to owners, 30 days', String(tp.sent_30d)]]} />
        <p className="small muted">An owner&apos;s alert names their car only: never the renter or the booking. Each owner switches each kind on their Notifications tab.</p>
        <h3 className="d4">Places watched</h3>
        <Table<R> rows={tp.places as unknown as R[]} rowKey={(x) => String(x.id)} empty="No places yet. Add the impound lots, auto shops and shipping ports to watch: a car that stops at one raises an alert for staff and its owner." cols={[
          { key: 'name', label: 'Place', className: 'wrap' }, { key: 'kind', label: 'Kind', render: (x) => KIND[String(x.kind)] ?? String(x.kind) },
          { key: 'where', label: 'Where', render: (x) => `${Number(x.latitude).toFixed(4)}, ${Number(x.longitude).toFixed(4)}` }, { key: 'radius_m', label: 'Within (m)', num: true },
          { key: 'is_active', label: 'Watched', render: (x) => yes(Boolean(x.is_active)) },
          { key: 'act', label: '', render: (x) => <span className="ad-actions">
            <Act action="tracker_place_save" payload={{ id: x.id }} label="Change" refresh={refresh} done="Saved." testId={`np-place-${String(x.id).slice(0, 8)}`} fields={placeFields(x)} />
            <Act action="tracker_place_remove" payload={{ id: x.id }} label="Remove" variant="quiet" confirm={`Stop watching ${String(x.name)}?`} refresh={refresh} done="Removed." /></span> }]} />
        <Act action="tracker_place_save" label="Add a place" variant="primary" refresh={refresh} done="Added." testId="np-place-add" title="A place to watch" fields={placeFields({})} />
      </Card>
    )}
  </>);
}

function placeFields(x: R) {
  return [
    { name: 'kind', label: 'Kind of place', type: 'select' as const, required: true, value: x.kind ?? 'impound', options: Object.entries(KIND) as Array<[string, string]> },
    { name: 'name', label: 'Name', type: 'text' as const, required: true, value: x.name ?? '', placeholder: 'For example: City impound lot, Port of Montreal' },
    { name: 'latitude', label: 'Latitude', type: 'number' as const, required: true, value: x.latitude ?? '', min: -90, max: 90, hint: 'From a map: right-click the place and copy the first number.' },
    { name: 'longitude', label: 'Longitude', type: 'number' as const, required: true, value: x.longitude ?? '', min: -180, max: 180 },
    { name: 'radius_m', label: 'Within how many metres', type: 'number' as const, value: x.radius_m ?? 300, min: 50, max: 5000 },
    { name: 'is_active', label: 'Watched', type: 'bool' as const, value: x.is_active ?? true },
    { name: 'note', label: 'Note', type: 'text' as const, value: x.note ?? '', wide: true }
  ];
}
