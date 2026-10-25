import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act, type Field } from '@/features/admin/Act';
import { $, Badge, Card, Kv, PageHead, Table, t } from '@/features/admin/ui';
import { ConnectForm, CopyField, RunButtons } from '@/features/partner-crm/PartnerCrmClient';
import { feedLinks } from '@/server/partner-feed';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Partner CRM', path: '/admin/settings/partners', noindex: true, description: 'A partner company\'s CRM link.' });

type R = Record<string, unknown>;
interface LinkRow {
  id: string; connected: boolean; enabled: boolean; location_id: string | null; token_hint: string | null; token_store: string | null; token_set_at: string | null; token_set_by_name: string | null;
  api_version: string; share_cars: boolean; share_owner_cars: boolean; share_rates: boolean; share_availability: boolean; share_photos: boolean; outbound_target: string; object_key: string;
  price_mode: string; price_adjust_bps: number; inbound_enabled: boolean; inbound_source: string; inbound_object_key: string | null; inbound_feed_url: string | null; inbound_publish: boolean;
  inbound_photos: boolean; inbound_blocks: boolean; leads_enabled: boolean; pipeline_id: string | null; pipeline_stage_id: string | null; inbound_stage_id: string | null; referral_code: string;
  feed_version: number; detected_target: string | null; last_sync_at: string | null; last_sync_ok: boolean | null; last_error: string | null; failing_since: string | null;
  last_counts: Record<string, unknown>; last_test_at: string | null; last_inbound_at: string | null; running: boolean;
  last_test: { ok?: boolean; error?: string | null; location?: { name?: string | null } | null; objects?: Array<{ key: string; label: string }>; pipelines?: Array<{ id: string; name: string; stages: Array<{ id: string; name: string }> }>; checks?: Record<string, { ok: boolean; note?: string }> };
}
interface Data {
  partner: { id: string; business_name: string; partner_number: string; markup_bps: number | null; commission_bps: number | null };
  link: LinkRow; shared: { company: number; program_owner: number; in_their_crm: number }; sample: R[]; partner_cars: number; inbound: R[]; runs: R[]; leads: R[];
  their_cars_for_link: Array<{ id: string; name: string }>;
}

const yes = (b: boolean) => (b ? 'Yes' : 'No');
const TARGET: Record<string, string> = { auto: 'Automatic (a custom object, or products when their plan has none)', custom_object: 'A custom object, "CarmaCars Vehicles"', products: 'Products (one per car, with a daily price)' };
const SOURCE: Record<string, string> = { auto: 'Automatic (the object named below, else their feed)', custom_object: 'A custom object in their CRM', products: 'Products in their CRM', feed: 'Their feed (JSON or CSV)', off: 'Off' };

// Admin > Settings > Partners > a partner (migration 0147): connect their GoHighLevel, what they see and at what price,
// their cars coming in, leads both ways, the feed and the widget, the last runs.
export default async function PartnerCrm({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read } = await page(`/admin/settings/partners/${id}`);
  const d = await read<Data | null>('partner_crm', { partner_id: id });
  if (!d) notFound();
  const l = d.link;
  const name = d.partner.business_name;
  const refresh = [`/admin/settings/partners/${id}`];
  const links = await feedLinks(id, l.feed_version);
  const objects = l.last_test?.objects ?? [];
  const pipelines = l.last_test?.pipelines ?? [];
  const stages: Array<[string, string]> = pipelines.flatMap((p) => p.stages.map((s) => [s.id, `${p.name}: ${s.name}`] as [string, string]));
  const save = (label: string, testId: string, fields: Field[], title?: string) => <Act action="partner_crm_save" payload={{ partner_id: id }} label={label} title={title ?? label} testId={testId} refresh={refresh} done="Saved." fields={fields} />;
  const status = !l.connected ? <Badge s="draft">Not connected</Badge> : !l.enabled ? <Badge s="paused">Paused</Badge> : l.last_sync_ok === false ? <Badge s="failed">Failing</Badge> : <Badge s="active">Connected</Badge>;
  const c = l.last_counts ?? {};
  return (
    <>
      <PageHead kicker={<><Link prefetch={false} className="link" href="/admin/settings">Settings</Link> · <Link prefetch={false} className="link" href="/admin/settings/partners">Partners</Link></>}
        title={<>{name} <span data-testid="crm-status">{status}</span></>}>
        <Link prefetch={false} className="btn btn--ghost btn--sm" href={`/admin/partners/${id}`}>Partner record</Link>
      </PageHead>

      <div className="ad-cols ad-cols--2">
        <Card title="Their GoHighLevel" testId="crm-connection">
          <Kv rows={[
            ['Status', l.connected ? (l.enabled ? (l.running ? 'Connected, a sync is running' : 'Connected') : 'Connected, paused') : 'Not connected yet'],
            ['Location', l.location_id ? `${l.location_id}${l.last_test?.location?.name ? ` (${l.last_test.location.name})` : ''}` : 'None yet'],
            ['Token', l.token_hint ? <span key="t" data-testid="crm-token-hint">Ending {l.token_hint}, {l.token_store === 'vault' ? 'in the vault' : 'in the local stand-in'}{l.token_set_at ? `, saved ${t(l.token_set_at)}` : ''}{l.token_set_by_name ? ` by ${l.token_set_by_name}` : ''}</span> : 'None'],
            ['Last test', l.last_test_at ? <span key="lt" data-testid="crm-last-test">{l.last_test?.ok ? 'Passed' : `Failed: ${l.last_test?.error ?? 'no answer'}`}, {t(l.last_test_at)}</span> : 'Not tested yet'],
            ['Last sync', l.last_sync_at ? <span key="ls" data-testid="crm-last-sync">{l.last_sync_ok ? 'Done' : `Failed: ${l.last_error ?? 'no answer'}`}, {t(l.last_sync_at)}</span> : 'Not yet (every 15 minutes, and soon after a change)'],
            ['Their CRM holds', l.detected_target ? (l.detected_target === 'custom_object' ? 'Our cars as "CarmaCars Vehicles" records' : 'Our cars as products') : 'Decided at the first sync']
          ]} />
          {l.failing_since && <p className="alert alert--warn" role="note"><span>Failing since {t(l.failing_since)}. Press Test connection; if the token was refused, ask {name} for a new one and paste it below.</span></p>}
          <RunButtons partnerId={id} connected={l.connected} />
          <ConnectForm partnerId={id} connected={l.connected} locationId={l.location_id} hint={l.token_hint} />
          <div className="ad-actions">
            {l.connected && <Act action="partner_crm_save" payload={{ partner_id: id, enabled: !l.enabled }} label={l.enabled ? 'Pause the link' : 'Resume the link'} testId="crm-pause" refresh={refresh}
              confirm={l.enabled ? `Nothing is sent to or read from ${name} until you resume. What is in their CRM stays there.` : undefined} />}
            {l.connected && <Act action="partner_crm_disconnect" payload={{ partner_id: id }} label="Disconnect" variant="danger" testId="crm-disconnect" refresh={refresh}
              confirm={`The token is deleted from the vault and nothing more is sent to ${name}. What is already in their CRM stays there.`} />}
            {save('Advanced', 'crm-advanced', [{ name: 'api_version', label: 'API version header', type: 'select', required: true, value: l.api_version, options: [['2021-07-28', '2021-07-28 (default)'], ['v3', 'v3'], ['2021-04-15', '2021-04-15']], hint: 'Custom objects try the other version by themselves when one is refused.' }])}
          </div>
          <details className="small"><summary>What {name} gives us</summary>
            <p>In their GoHighLevel sub-account: Settings &gt; Private Integrations &gt; Create new Integration, named &quot;CarmaCars&quot;, with the scopes: View Locations; View and Edit Objects (schema and records); View and Edit Custom Fields; View and Edit Products and Product Prices; View Opportunities; and, for leads, Edit Opportunities and View and Edit Contacts. They copy the token (shown once) and send it with the location ID from their address bar, by phone or in person, never by plain email. Tokens should be renewed every 90 days.</p>
          </details>
        </Card>

        <Card title={`What ${name} sees`} testId="crm-outbound" aside={save('Change what we share', 'crm-share', [
            { name: 'share_cars', label: 'Send our cars to their CRM', type: 'bool', value: l.share_cars },
            { name: 'share_owner_cars', label: 'Include program owners\' cars (CarmaCars\' own cars always go)', type: 'bool', value: l.share_owner_cars },
            { name: 'share_rates', label: 'Rates', type: 'bool', value: l.share_rates },
            { name: 'share_availability', label: 'Availability (next 60 days)', type: 'bool', value: l.share_availability },
            { name: 'share_photos', label: 'Photos', type: 'bool', value: l.share_photos },
            { name: 'outbound_target', label: 'In their CRM as', type: 'select', required: true, value: l.outbound_target, options: Object.entries(TARGET) },
            { name: 'object_key', label: 'Key of our object in their CRM', type: 'text', required: true, value: l.object_key, hint: 'Lowercase letters, digits and _. Changing it starts a new object.' }])}>
          <Kv rows={[
            ['Cars they see', <span key="n" data-testid="crm-shared-count">{d.shared.company + d.shared.program_owner} ({d.shared.company} CarmaCars, {d.shared.program_owner} program owners)</span>],
            ['In their CRM now', String(d.shared.in_their_crm)],
            ['Never sent', 'Partner cars: theirs and any other partner\'s'],
            ['Shared', [l.share_rates && 'rates', l.share_availability && 'availability', l.share_photos && 'photos'].filter(Boolean).join(', ') || 'the cars only'],
            ['Partner price', <span key="p" data-testid="crm-price-rule">{l.price_mode === 'site' ? 'The site\'s rates' : `The site's rates ${l.price_adjust_bps < 0 ? 'less' : 'plus'} ${Math.abs(l.price_adjust_bps) / 100}%, to the nearest dollar`}</span>],
            ['Last sync', l.last_sync_at ? `${Number(c.cars ?? 0)} cars: ${Number(c.created ?? 0)} added, ${Number(c.updated ?? 0)} changed, ${Number(c.unchanged ?? 0)} unchanged, ${Number(c.removed ?? 0)} removed${Number(c.failed ?? 0) ? `, ${Number(c.failed)} failed` : ''}` : 'Not yet']
          ]} />
          <div className="ad-actions">{save('Partner price', 'crm-price', [
            { name: 'price_mode', label: 'They see', type: 'select', required: true, value: l.price_mode, options: [['site', 'The site\'s rates'], ['percent', 'The site\'s rates adjusted by a percentage']] },
            { name: 'price_adjust_bps', label: 'Adjustment (negative: below the site, for example -10)', type: 'percent', value: l.price_adjust_bps, hint: 'Between -50% and 50%. Rounded to the nearest dollar.' }])}</div>
          {d.sample.length > 0 && <Table rows={d.sample} rowKey={(x) => String(x.vehicle_id)} caption="First cars they see" testId="crm-sample" cols={[
            { key: 'name', label: 'Car', render: (x) => <>{String(x.name)}<span className="ad-sub">{String(x.car_code ?? '')} · {x.supply_type === 'company' ? 'CarmaCars' : 'program owner'}</span></> },
            { key: 'daily_cents', label: 'A day', num: true, render: (x) => (x.daily_cents == null ? 'Not shared' : $(x.daily_cents)) },
            { key: 'availability', label: 'Next free', render: (x) => { const a = x.availability as { next_free_date?: string | null; available_today?: boolean } | null; return !a ? 'Not shared' : a.available_today ? 'Today' : a.next_free_date ?? 'None in 60 days'; } }]} />}
        </Card>

        <Card title={`${name}'s cars coming in`} testId="crm-inbound" aside={save('Change where their cars come from', 'crm-inbound-settings', [
            { name: 'inbound_enabled', label: 'Bring their cars to CarmaCars', type: 'bool', value: l.inbound_enabled },
            { name: 'inbound_source', label: 'From', type: 'select', required: true, value: l.inbound_source, options: Object.entries(SOURCE) },
            { name: 'inbound_object_key', label: 'Their object that holds their cars', type: objects.length ? 'select' : 'text', value: l.inbound_object_key,
              options: objects.filter((o) => !o.key.endsWith(`.${l.object_key}`)).map((o) => [o.key, `${o.label} (${o.key})`] as [string, string]),
              hint: objects.length ? 'From the last Test connection.' : 'Press Test connection to list their objects, or type the key (custom_objects.vehicles).' },
            { name: 'inbound_feed_url', label: 'Or their feed address', type: 'text', value: l.inbound_feed_url, placeholder: 'https://...' },
            { name: 'inbound_publish', label: 'A car not here yet goes on the site at once (otherwise it waits for you)', type: 'bool', value: l.inbound_publish },
            { name: 'inbound_photos', label: 'Copy their photos to a car with none of its own', type: 'bool', value: l.inbound_photos },
            { name: 'inbound_blocks', label: 'Their booked dates block our calendar', type: 'bool', value: l.inbound_blocks }])}>
          <p className="small muted">Their rates become the car&apos;s sheet rates; the renter pays them plus the markup ({d.partner.markup_bps == null ? 'Program settings' : `${d.partner.markup_bps / 100}%`}) and CarmaCars keeps its cut, as on the partner record. {d.partner_cars} of their cars are here now.{l.last_inbound_at ? ` Last read ${t(l.last_inbound_at)}.` : ''}</p>
          <Table rows={d.inbound} rowKey={(x) => String(x.id)} empty={l.inbound_enabled ? 'Nothing read yet. Name their object or feed, then Run sync now.' : 'Off.'} testId="crm-inbound-items" cols={[
            { key: 'name', label: 'Their car', render: (x) => <>{String(x.name ?? x.remote_id)}<span className="ad-sub">{String(x.remote_kind).replace('_', ' ')}{Number(x.photos) ? `, ${String(x.photos)} photos` : ''}</span></> },
            { key: 'base_cents', label: 'A day', num: true, render: (x) => (x.base_cents ? $(Number(x.base_cents)) : '') },
            { key: 'status', label: 'Here', render: (x) => <>{x.vehicle_id ? <Link prefetch={false} className="link" href={`/admin/vehicles/${String(x.vehicle_id)}`}>{String(x.vehicle_name ?? 'Car')}</Link> : <Badge s={String(x.status)}>{String(x.status)}</Badge>}{x.message ? <span className="ad-sub">{String(x.message)}</span> : null}</> },
            { key: 'id', label: '', render: (x) => x.status === 'skipped' || x.status === 'gone'
              ? <Act action="partner_crm_inbound_item" payload={{ id: x.id, action: 'review' }} label="Bring back" refresh={refresh} />
              : <div className="ad-actions">
                  {!x.vehicle_id && <Act action="partner_crm_inbound_item" payload={{ id: x.id, action: 'add' }} label="Add as their car" title={`Add ${String(x.name ?? '')}`} refresh={refresh}
                    fields={[{ name: 'publish', label: 'Put it on the site now', type: 'bool', value: false }]} />}
                  {d.their_cars_for_link.length > 0 && <Act action="partner_crm_inbound_item" payload={{ id: x.id, action: 'link' }} label={x.vehicle_id ? 'Change car' : 'Link'} title="Which of their cars is it?" refresh={refresh}
                    fields={[{ name: 'vehicle_id', label: 'Their car here', type: 'select', required: true, value: x.vehicle_id, options: d.their_cars_for_link.map((v) => [v.id, v.name] as [string, string]) }]} />}
                  <Act action="partner_crm_inbound_item" payload={{ id: x.id, action: 'skip' }} label="Set aside" refresh={refresh} />
                </div> }]} />
        </Card>

        <Card title="Leads both ways" testId="crm-leads" aside={save('Change leads', 'crm-leads-settings', [
            { name: 'leads_enabled', label: `Send ${name} the requests for their cars and the ones their links bring us`, type: 'bool', value: l.leads_enabled, hint: 'Name, email, phone, car, dates and total of each request.' },
            { name: 'pipeline_id', label: 'Their pipeline', type: pipelines.length ? 'select' : 'text', value: l.pipeline_id, options: pipelines.map((p) => [p.id, p.name] as [string, string]) },
            { name: 'pipeline_stage_id', label: 'Stage for the leads we send', type: stages.length ? 'select' : 'text', value: l.pipeline_stage_id, options: stages },
            { name: 'inbound_stage_id', label: 'Stage that sends leads to us (empty: none)', type: stages.length ? 'select' : 'text', value: l.inbound_stage_id, options: stages, hint: 'An opportunity they move to this stage becomes a lead in Admin > Leads.' }])}>
          <p className="small muted">{l.leads_enabled ? 'On.' : 'Off. Turn it on once they agree to receive renters\' contact details (they are the renter\'s rental company for their own cars).'} {pipelines.length ? '' : 'Press Test connection to list their pipelines.'}</p>
          <Table rows={d.leads} rowKey={(x) => `${String(x.created_at)}-${String(x.booking_number ?? x.lead_id)}`} empty="No leads yet." cols={[
            { key: 'direction', label: 'Way', render: (x) => (x.direction === 'to_partner' ? `To ${name}` : `From ${name}`) },
            { key: 'booking_number', label: 'Booking or lead', render: (x) => (x.booking_number ? <Link prefetch={false} className="link" href={`/admin/bookings/${encodeURIComponent(String(x.booking_number))}`}>{String(x.booking_number)}</Link> : x.lead_id ? <Link prefetch={false} className="link" href="/admin/leads">Lead</Link> : '') },
            { key: 'status', label: 'Status', render: (x) => <>{String(x.status)}{x.error ? <span className="ad-sub">{String(x.error)}</span> : null}</> },
            { key: 'created_at', label: 'When', render: (x) => t(x.created_at) }]} />
        </Card>

        <Card title="Feed, widget and booking links" testId="crm-feed">
          <p className="small muted">For their own automations and sites. The same cars and prices as the sync. The key is in the address: New key ends the old addresses at once.</p>
          <CopyField label="Feed (JSON)" value={links.json} testId="crm-feed-json" />
          <CopyField label="Feed (CSV, for a spreadsheet)" value={links.csv} testId="crm-feed-csv" />
          <CopyField label="Widget (for a GoHighLevel funnel or site: Custom code or an iframe element)" value={links.iframe} testId="crm-widget" />
          <Kv rows={[['Booking links', <span key="b">carmacars.ca/p/<b>{l.referral_code}</b>/&lt;car&gt;: a request after their link is marked as theirs for 30 days</span>]]} />
          <div className="ad-actions">
            <Act action="partner_crm_feed_rotate" payload={{ partner_id: id }} label="New key" testId="crm-feed-rotate" refresh={refresh} confirm="The feed and widget addresses change; the old ones stop working at once." />
            {save('Change the booking link code', 'crm-code', [{ name: 'referral_code', label: 'Code', type: 'text', required: true, value: l.referral_code, hint: 'Lowercase letters, digits and dashes. Links already sent with the old code stop counting.' }])}
          </div>
        </Card>

        <Card title="Recent runs" testId="crm-runs">
          <Table rows={d.runs} rowKey={(x) => String(x.started_at)} empty="No runs yet." cols={[
            { key: 'kind', label: 'Run', render: (x) => <>{x.kind === 'test' ? 'Test' : 'Sync'}{x.by ? <span className="ad-sub">by {String(x.by)}</span> : null}</> },
            { key: 'started_at', label: 'When', render: (x) => t(x.started_at) },
            { key: 'ok', label: 'Result', render: (x) => (x.ok == null ? 'Running' : x.ok ? 'Done' : <span className="ad-err">{String(x.error ?? 'Failed')}</span>) },
            { key: 'counts', label: 'Counts', render: (x) => { const k = (x.counts ?? {}) as Record<string, unknown>; return <span className="small">{Object.entries(k).filter(([, v]) => typeof v === 'number' && v).map(([a, v]) => `${a.replace(/_/g, ' ')} ${String(v)}`).join(', ')}</span>; } }]} />
          <p className="small muted">Automatic every 15 minutes, and within five minutes of a change to a car, a rate, a photo, a booking or a block. Shared: {yes(l.share_cars)}; their cars: {yes(l.inbound_enabled)}; leads: {yes(l.leads_enabled)}.</p>
        </Card>
      </div>
    </>
  );
}
