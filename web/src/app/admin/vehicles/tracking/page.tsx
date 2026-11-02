import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { requireAdmin } from '@/server/admin/data';
import { door } from '@/server/door';
import { Act } from '@/features/admin/Act';
import { Card, PageHead, Table, t } from '@/features/admin/ui';
import { FleetTracking } from '@/features/tracking/FleetTracking';
import { IngestKey } from '@/features/tracking/IngestKey';
import type { Fleet, TrackedCar, Unpaired } from '@/features/tracking/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Fleet tracking', path: '/admin/vehicles/tracking', noindex: true, description: 'Every car on the map with its renter, trips, alerts and trackers.' });

const R = ['/admin/vehicles/tracking'];

// Cars > Fleet tracking (migration 0400): part of Cars, beside the list (the Vehicles and Fleet tracking tabs), not a page
// of its own in the menu. The live panel, then the trackers (pair, replace, remove) and the settings.
export default async function Tracking() {
  const { user } = await requireAdmin('/admin/vehicles/tracking');
  const f = await door<Fleet>(user.id, 'ops_read', 'tracker_fleet').catch(() => null);
  const at = new Date().getTime();
  const s = f?.settings;
  const carOptions = (f?.cars ?? []).map((c) => [c.vehicle_id, `${c.name}${c.code ? ` (${c.code})` : ''}${c.device ? ' · has a tracker' : ''}`] as [string, string]);
  const paired = (f?.cars ?? []).filter((c) => c.device);
  const today = new Date(at).toLocaleDateString('en-CA', { timeZone: 'America/Toronto' });
  const pairFields = (device?: string) => [
    ...(device ? [] : [{ name: 'device', label: 'Device ID (IMEI or serial)', type: 'text' as const, required: true, hint: 'Printed on the tracker or its box; the same ID it reports with.' }]),
    { name: 'vehicle_id', label: 'Car', type: 'select' as const, required: true, options: carOptions },
    { name: 'installed_on', label: 'Installed on', type: 'date' as const, required: true, value: today, hint: 'Starts the Tracker Fee on the owner\'s invoice when the car has none yet (a replacement keeps the first date).' },
    { name: 'sim', label: 'SIM card number (ICCID)', type: 'text' as const }];
  return (
    <>
      <PageHead title="Fleet tracking" kicker="Cars" purpose="Where every car is now, who has it, its trips and the alerts. The trackers and their settings are below the map.">
        <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/live-map">Live map</Link>
      </PageHead>
      {f ? <FleetTracking initial={f} at={at} /> : <p className="alert alert--error" role="alert"><span>Fleet tracking could not be read. Reload the page.</span></p>}

      <div className="stack" style={{ marginTop: 24 }}>
        <Card title={`Trackers (${paired.length} on cars)`} id="trackers" testId="trackers"
          aside={<Act ops action="tracker_pair" label="Pair a tracker" variant="primary" fields={pairFields()} refresh={R} done="Paired." testId="pair" />}>
          {f && f.unpaired.length > 0 && <>
            <p className="small"><b>Reporting, not on a car yet.</b> Pair each with the car it is in.</p>
            <Table<Unpaired> testId="unpaired" caption="Trackers not on a car" rows={f.unpaired} empty="" cols={[
              { key: 'serial', label: 'Device ID', render: (u) => <code>{u.serial}</code> }, { key: 'last_seen', label: 'Last report', render: (u) => t(u.last_seen) },
              { key: 'battery', label: 'Battery', render: (u) => (u.battery != null ? `${u.battery}%` : '') }, { key: 'status', label: 'State', render: (u) => (u.status === 'removed' ? 'taken off a car' : 'new') },
              { key: 'act', label: '', render: (u) => <Act ops action="tracker_pair" payload={{ device: u.serial }} label="Pair" variant="primary" fields={pairFields(u.serial)} refresh={R} done="Paired." testId={`pair-${u.serial}`} /> }]} />
          </>}
          <Table<TrackedCar> testId="paired" caption="Trackers on cars" rows={paired} empty="No tracker is paired yet. Press Pair a tracker, or wait for a new tracker to report and pair it from the list above." cols={[
            { key: 'name', label: 'Car', render: (c) => <Link prefetch={false} className="link" href={`/admin/vehicles/${c.vehicle_id}?tab=records`}>{c.name}</Link> },
            { key: 'serial', label: 'Device ID', render: (c) => <code>{c.device!.serial}</code> },
            { key: 'installed', label: 'Installed', render: (c) => (c.device!.installed_at ? t(c.device!.installed_at).split(',')[0] : '') },
            { key: 'fee', label: 'Tracker Fee from', render: (c) => c.device!.fee_from ?? '' },
            { key: 'seen', label: 'Last report', render: (c) => (c.pos ? t(c.pos.at) : 'not yet') },
            { key: 'battery', label: 'Battery', render: (c) => (c.pos?.battery != null ? `${c.pos.battery}%` : '') },
            { key: 'act', label: '', render: (c) => <Act ops action="tracker_unpair" payload={{ device_id: c.device!.id }} label="Remove" confirm={`Take this tracker off the ${c.name}? Its trip ends and it stops showing on the map. The Tracker Fee is not changed.`}
              fields={[{ name: 'faulty', label: 'The tracker is faulty', type: 'bool' }]} refresh={R} done="Removed." testId={`unpair-${c.device!.serial}`} /> }]} />
        </Card>

        {s && <Card title="Tracking settings" id="settings" testId="tracking-settings">
          <Act ops inline action="tracker_settings_save" label="Save the settings" submitLabel="Save the settings" refresh={R} done="Saved." testId="tracking-settings" fields={[
            { name: 'speed_alert_kmh', label: 'Speeding alert at (km/h)', type: 'number', min: 60, max: 250, required: true, value: s.speed_alert_kmh },
            { name: 'overdue_grace_minutes', label: 'Still driving after the return time: minutes of grace', type: 'number', min: 0, max: 240, required: true, value: s.overdue_grace_minutes },
            { name: 'battery_low_pct', label: 'Low tracker battery below (%)', type: 'number', min: 1, max: 90, required: true, value: s.battery_low_pct },
            { name: 'offline_hours', label: 'Not reporting alert after (hours)', type: 'number', min: 1, max: 168, required: true, value: s.offline_hours },
            { name: 'ontario_alert', label: 'Alert when a car leaves Ontario', type: 'bool', value: s.ontario_alert },
            { name: 'zone_name', label: 'Optional zone: its name', type: 'text', value: s.zone_name ?? '', placeholder: 'GTA', hint: 'Alert when a car goes farther than the radius from the centre. Leave the name empty for no zone.' },
            { name: 'zone_lat', label: 'Zone centre latitude', type: 'number', min: 41, max: 57, value: s.zone_lat ?? '' },
            { name: 'zone_lng', label: 'Zone centre longitude', type: 'number', min: -96, max: -74, value: s.zone_lng ?? '' },
            { name: 'zone_radius_km', label: 'Zone radius (km)', type: 'number', min: 1, max: 1000, value: s.zone_radius_km ?? '' },
            { name: 'history_seconds', label: 'Keep a moving car\'s position every (seconds)', type: 'number', min: 10, max: 3600, required: true, value: s.history_seconds, hint: 'Fewer points keep the database small; the map always shows the latest position.' },
            { name: 'history_days', label: 'Keep the position history (days)', type: 'number', min: 7, max: 365, required: true, value: s.history_days, hint: 'At most 365: the privacy policy keeps tracker data 12 months.' },
            { name: 'trip_days', label: 'Keep trips and alerts (days)', type: 'number', min: 30, max: 365, required: true, value: s.trip_days },
            { name: 'demo', label: 'Demo mode: simulated cars drive the GTA (here and on the Live map)', type: 'bool', value: s.demo, hint: 'For a demonstration or screenshots. Nothing is written; turn it off before the trackers go live.' }]} />
          <h3 className="h4" style={{ marginTop: 20 }}>Ingest key</h3>
          <IngestKey hasKey={s.key_set} hint={s.key_hint} />
          <p className="small muted">Trackers report to <code>/api/tracker/ingest</code> through the relay on the server (GT06 or JT808) or the tracker company&apos;s push. The format and the relay are in the developer notes (docs/tracker-ingest.md).</p>
        </Card>}
      </div>
    </>
  );
}
