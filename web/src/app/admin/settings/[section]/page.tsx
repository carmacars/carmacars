import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act, SaveForm, type Field } from '@/features/admin/Act';
import { fieldsFrom } from '@/features/admin/fields';
import { LogoUpload } from '@/features/admin/SettingsClient';
import { InviteForm, PasswordLinkButton } from '@/features/admin/AccountTools';
import { ViewAsButton } from '@/features/admin/ViewAs';
import { $, Badge, Card, PageHead, Table, d, t, label } from '@/features/admin/ui';
import { SECTIONS } from '../sections';
import { door } from '@/server/door';
import { OfficialForms, type FormsData } from '@/features/official-forms/OfficialForms';
import { StaffAgreements, type StaffAgreementRow } from '@/features/manual/StaffAgreements';
import { AdminAccessForm, SampleRowActions, SampleThumb, SampleUpload } from '@/features/admin/SamplePhotosClient';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Settings', path: '/admin/settings', noindex: true, description: 'Settings.' });

type R = Record<string, unknown>;
type S = { site: R; program: R; program_rows: R[]; content: R[]; fee_types: R[]; fee_defaults: R[]; deposit_tiers: R[]; km_choices: R[]; classes: R[]; airports: R[]; coverage: R[];
  email_aliases: R[]; reply_to: R[]; insurers: R[]; promo_codes: R[]; quick_replies: R[]; staff: R[]; problems: Array<{ field: string; message: string }> };

const SITE_GROUPS: Array<[string, string[]]> = [
  ['Brand and tagline', ['brand_name', 'tagline', 'wordmark_text', 'logo_alt', 'logo_width', 'logo_height', 'site_url']],
  ['Contact', ['phone', 'phone_display', 'whatsapp', 'whatsapp_display', 'roadside_phone', 'roadside_phone_display', 'public_email', 'owners_email', 'mailing_address', 'street_address', 'show_street_address']],
  ['Hours and handover', ['opening_hours_text', 'handover_any_time', 'handover_slots', 'city', 'region', 'service_area', 'delivery_area_text', 'delivery_areas', 'airport_delivery']],
  ['Social, reviews and search', ['social_links', 'google_place_id', 'review_source', 'reply_wording', 'seo_default_title', 'seo_title_suffix', 'seo_default_description', 'listing_time_promise', 'featured_mode']]
];
const PROGRAM_GROUPS: Array<[string, (k: string) => boolean]> = [
  ['Company', (k) => k.startsWith('company_') || ['incident_line_phone', 'privacy_officer_name', 'privacy_officer_email', 'signing_officer_name', 'signing_officer_title', 'timezone', 'hst_bps'].includes(k)],
  ['Booking requests and offers', (k) => /^(booking_|offer_|request_|max_|min_|standard_min|accepted_licence|other_licence|info_request|tentative|turnaround|non_refundable|verification|early_return|chase_)/.test(k)],
  ['Owner debits and statement emails', (k) => /^(owner_debit_|billing_day|retry_day|owner_late_fee|owner_statement_email|company_statement_email)/.test(k)],
  ['Deposits, refunds and money', (k) => /^(deposit_|refund_|statement_|holdback|insurer_|liability|deductible|kickback|shareholder|install_fee|owner_late|billing_day|retry_day|payout_day|fleet_report_day|investor_|buyout|take_deposit)/.test(k)],
  ['Delivery', (k) => k.startsWith('delivery_') || ['company_latitude', 'company_longitude'].includes(k)],
  ['Owners and fleet', (k) => /^(notice_period|free_retransfer|owner_|retransfer|total_loss|min_fleet|fleet_warning|safety_|fee_change|trackers_available|tracker_|plate_renewal|turo_|provisional_)/.test(k)],
  ['Tolls and damage', (k) => /^(toll_|damage_|incident_)/.test(k)],
  ['Listings', (k) => k.startsWith('listing_') || k.startsWith('photo_') || k.startsWith('plate_')],
  ['Vision model', (k) => k.startsWith('ai_vision')],
  ['Email and notifications', (k) => k.startsWith('notify_')],
  ['Partners, rentals added by hand and agreements', (k) => /^(partner_|manual_rental_|staff_agreement_)/.test(k)],
  ['Staff, privacy and housekeeping', () => true]
];
const yes = (v: unknown) => (v ? 'Yes' : 'No');

export default async function Section({ params }: { params: Promise<{ section: string }> }) {
  const { section } = await params;
  const meta = SECTIONS.find(([k]) => k === section);
  if (!meta) notFound();
  const { read, user } = await page(`/admin/settings/${section}`);
  const s = await read<S>('settings');
  const back = <Link prefetch={false} className="link" href="/admin/settings">Settings</Link>;
  const head = <PageHead kicker={back} title={meta[1]} />;
  const classOpts = (s.classes as Array<{ code: string; label: string }>).map((c) => [c.code, c.label] as [string, string]);

  switch (section) {
  case 'site':
    return (<>{head}
      {s.problems.length > 0 && <Card title="Still missing" tone="warn"><ul className="small">{s.problems.map((p) => <li key={p.field}>{p.message}</li>)}</ul></Card>}
      {SITE_GROUPS.map(([title, keys]) => <Card key={title} title={title}><SaveForm table="site_settings" rowKey="singleton" testId={`site-${title.split(' ')[0]!.toLowerCase()}`} fields={fieldsFrom(s.site, keys, { featured_mode: [['random', 'Random'], ['manual', 'Chosen by hand']] })} /></Card>)}
      <Card title="Logo"><p className="small muted">Light: {String(s.site.logo_light_file_key ?? 'none, the wordmark is shown')}. Dark: {String(s.site.logo_dark_file_key ?? 'none')}.</p><div className="ad-cols ad-cols--2"><LogoUpload which="light" /><LogoUpload which="dark" /></div></Card>
      <Card title="Browser icon and sharing image"><p className="small muted">Icon: {String(s.site.favicon_file_key ?? 'none, the drawn stand-in is shown')}. Sharing image: {String(s.site.og_image_file_key ?? 'none, the built-in image is used')}.</p><div className="ad-cols ad-cols--2"><LogoUpload which="favicon" /><LogoUpload which="og" /></div></Card>
    </>);
  case 'content':
    return (<>{head}
      <p className="small muted">Text may carry tokens such as {'{{phone}}'} that are filled from settings. An unpublished block is not shown.</p>
      {[...new Set(s.content.map((c) => String(c.page)))].map((p) => (
        <Card key={p} title={`Page: ${p}`}>{s.content.filter((c) => c.page === p).map((c) => (
          <details key={String(c.id)}><summary className="link">{String(c.block_key)} <span className="muted small">({String(c.kind)}{c.is_published ? '' : ', not published'})</span></summary>
            <SaveForm table="site_content_blocks" rowKey={String(c.id)} fields={[{ name: 'body', label: 'Text', type: 'textarea', value: c.body, wide: true }, { name: 'data', label: 'Items (headings, FAQs, lists)', type: 'json', value: c.data }, { name: 'sort_order', label: 'Order', type: 'number', value: c.sort_order }, { name: 'is_published', label: 'Published', type: 'bool', value: c.is_published }]} />
          </details>))}</Card>))}
      <Card title="Add a block"><SaveForm table="site_content_blocks" label="Add" fields={[{ name: 'block_key', label: 'Key', required: true }, { name: 'page', label: 'Page', required: true }, { name: 'kind', label: 'Kind', type: 'select', options: [['text', 'Text'], ['rich_text', 'Rich text'], ['faq', 'FAQ'], ['list', 'List']], required: true, value: 'text' }, { name: 'body', label: 'Text', type: 'textarea' }, { name: 'is_published', label: 'Published', type: 'bool', value: true }]} /></Card>
    </>);
  case 'sample-photos': {
    // a car listed without real photos shows sample photos (0054): the library, the built-in pictures, the cars using them
    const sp = await door<{ photos: Array<{ id: string; body_type: string | null; make: string | null; model: string | null; path: string; alt: string; active: boolean }>; builtin: string[];
      using: Array<{ vehicle_id: string; vehicle: string; listing_status: string | null; body_key: string; photos: Array<{ path: string; alt: string }> }> }>(user.id, 'ops_read', 'sample_photos');
    return (<>{head}
      <p className="small muted">A car with no real photos can still be listed and published. Until real photos are added and approved, its listing shows sample photos, marked &quot;Sample photo&quot; on the site. Real photos replace them automatically. The licence plate check does not apply to sample photos.</p>
      <Card title={`Cars using sample photos (${sp.using.length})`} testId="sample-using">
        <Table rows={sp.using as unknown as R[]} rowKey={(r) => String(r.vehicle_id)} empty="Every car has real photos." cols={[
          { key: 'photo', label: 'Shows', render: (r) => { const ph = (r.photos as Array<{ path: string; alt: string }>)[0]; return ph ? <SampleThumb path={ph.path} alt={ph.alt} /> : ''; } },
          { key: 'vehicle', label: 'Car', render: (r) => <Link prefetch={false} className="link" href={`/admin/vehicles/${String(r.vehicle_id)}`}>{String(r.vehicle)}</Link> },
          { key: 'listing_status', label: 'Listing', render: (r) => <Badge s={String(r.listing_status ?? 'none')} /> },
          { key: 'body_key', label: 'Body type', render: (r) => label(r.body_key) },
          { key: 'act', label: 'Next', render: (r) => <Link prefetch={false} className="link small" href={`/admin/vehicles/${String(r.vehicle_id)}?tab=listing`}>Add real photos</Link> }]} />
      </Card>
      <Card title="Add a sample photo" testId="sample-add-card"><SampleUpload /></Card>
      <Card title={`Library (${sp.photos.length})`} testId="sample-library">
        <Table rows={sp.photos as unknown as R[]} empty="No library photos yet. Cars show the built-in picture of their body type." cols={[
          { key: 'path', label: 'Photo', render: (r) => <SampleThumb path={String(r.path)} alt={String(r.alt)} /> },
          { key: 'for', label: 'Used for', render: (r) => [r.make, r.model].filter(Boolean).join(' ') || label(r.body_type) },
          { key: 'body_type', label: 'Body type', render: (r) => label(r.body_type) || 'any' },
          { key: 'active', label: 'On', render: (r) => (r.active ? 'Yes' : 'No') },
          { key: 'act', label: 'Actions', render: (r) => <SampleRowActions id={String(r.id)} active={!!r.active} /> }]} />
      </Card>
      <Card title="Built-in pictures">
        <div className="ad-chip-row">{sp.builtin.map((b) => <figure key={b} style={{ margin: 0 }}><SampleThumb path={`/sample-photos/${b}.jpg`} alt={`Built-in sample picture: ${label(b)}`} /><figcaption className="small muted">{label(b)}</figcaption></figure>)}</div>
      </Card>
    </>);
  }
  case 'forms':
    return (<>{head}<OfficialForms d={await door<FormsData>(user.id, 'ops_read', 'form_templates')} /></>);
  case 'program': {
    // turnaround_block_minutes always equals the turnaround (0042): one setting is shown
    const keys = Object.keys(s.program).filter((k) => !['id', 'effective_from', 'created_by', 'created_at', 'turnaround_block_minutes'].includes(k));
    const used = new Set<string>();
    return (<>{head}
      <p className="small muted">Saving writes a new dated row from today; the rows before it stay as they were. In force since {d(s.program.effective_from)}; {s.program_rows.length} dated rows.</p>
      <Card title="Turnaround between trips" testId="turnaround-help"><p className="small">One time between trips, {String(s.program.turnaround_buffer_minutes)} minutes now (the owner&apos;s 2 hours by default). No trip may start sooner after another one ends, and a trip must end that long before the next one starts. After each trip the same time shows on the calendars as the cleaning block; it is not added on top. Removing a cleaning block frees that time for a new booking. A car can have its own turnaround under Vehicles, the car, Calendar. Change it under Booking requests and offers.</p></Card>
      {PROGRAM_GROUPS.map(([title, test]) => { const ks = keys.filter((k) => !used.has(k) && test(k)); ks.forEach((k) => used.add(k)); if (!ks.length) return null; return (
        <Card key={title} title={title}><details open={title === 'Booking requests and offers'}><summary className="link">{ks.length} settings</summary>
          <SaveForm table="program_settings" rowKey="current" testId={`program-${title.split(' ')[0]!.toLowerCase()}`} fields={fieldsFrom(s.program, ks)} /></details></Card>); })}
    </>);
  }
  case 'fees':
    return (<>{head}
      <Card title="Defaults in force"><Table rows={s.fee_defaults} cols={[{ key: 'fee_type_code', label: 'Fee', render: (r) => String((s.fee_types.find((f) => f.code === r.fee_type_code) ?? {}).label ?? r.fee_type_code) }, { key: 'vehicle_class', label: 'Class', render: (r) => r.vehicle_class ? String(r.vehicle_class) : 'all' },
        { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'percent_bps', label: '%', num: true, render: (r) => r.percent_bps !== null ? `${Number(r.percent_bps) / 100}%` : '' }, { key: 'cap_cents', label: 'Cap', num: true, render: (r) => $(r.cap_cents) },
        { key: 'min_cents', label: 'Min', num: true, render: (r) => $(r.min_cents) }, { key: 'max_cents', label: 'Max', num: true, render: (r) => $(r.max_cents) }, { key: 'effective_from', label: 'From', render: (r) => d(r.effective_from) }]} /></Card>
      <Card title="Set a new default"><SaveForm table="fee_defaults" label="Save the new default" fields={[{ name: 'fee_type_code', label: 'Fee', type: 'select', required: true, options: s.fee_types.map((f) => [String(f.code), String(f.label)]) }, { name: 'vehicle_class', label: 'Class (empty: all)', type: 'select', options: [['economy', 'Economy'], ['standard', 'Standard'], ['premium', 'Premium'], ['luxury', 'Luxury'], ['exotic', 'Exotic']] },
        { name: 'amount_cents', label: 'Amount', type: 'money' }, { name: 'percent_bps', label: 'Percentage', type: 'percent' }, { name: 'cap_cents', label: 'Cap', type: 'money' }, { name: 'min_cents', label: 'Minimum', type: 'money' }, { name: 'max_cents', label: 'Maximum', type: 'money' }, { name: 'grace_minutes', label: 'Grace minutes', type: 'number' }, { name: 'effective_from', label: 'Effective from', type: 'date', value: new Date().toISOString().slice(0, 10) }, { name: 'note', label: 'Note' }]} /></Card>
    </>);
  case 'deposits': case 'km': case 'classes': case 'airports': case 'insurers': case 'promo-codes': case 'quick-replies': {
    const cfg: Record<string, { table: string; key: string; rows: R[]; fields: (r: R) => Field[]; extra?: React.ReactNode }> = {
      deposits: { table: 'deposit_tiers', key: 'amount_cents', rows: s.deposit_tiers, fields: (r) => [{ name: 'amount_cents', label: 'Amount', type: 'money', required: true, value: r.amount_cents }, { name: 'label', label: 'Label', required: true, value: r.label }, { name: 'sort_order', label: 'Order', type: 'number', value: r.sort_order }, { name: 'is_active', label: 'Offered', type: 'bool', value: r.is_active ?? true }] },
      km: { table: 'km_allowance_choices', key: 'km_per_day', rows: s.km_choices, fields: (r) => [{ name: 'km_per_day', label: 'Kilometres a day (0 unlimited)', type: 'number', required: true, value: r.km_per_day }, { name: 'sort_order', label: 'Order', type: 'number', value: r.sort_order }, { name: 'is_active', label: 'Offered', type: 'bool', value: r.is_active ?? true }] },
      classes: { table: 'vehicle_classes', key: 'code', rows: s.classes, fields: (r) => [{ name: 'code', label: 'Code', required: true, value: r.code }, { name: 'label', label: 'Label', required: true, value: r.label }, { name: 'sort_order', label: 'Order', type: 'number', value: r.sort_order }, { name: 'is_active', label: 'Shown', type: 'bool', value: r.is_active ?? true }] },
      airports: { table: 'airports', key: 'id', rows: s.airports, fields: (r) => [{ name: 'code', label: 'Code', required: true, value: r.code }, { name: 'name', label: 'Name', required: true, value: r.name }, { name: 'latitude', label: 'Latitude', type: 'number', required: true, value: r.latitude }, { name: 'longitude', label: 'Longitude', type: 'number', required: true, value: r.longitude }, { name: 'distance_km', label: 'Distance (km)', type: 'number', value: r.distance_km }, { name: 'surcharge_cents', label: 'Surcharge', type: 'money', value: r.surcharge_cents }, { name: 'is_active', label: 'Offered', type: 'bool', value: r.is_active ?? true }],
        extra: <Card title="Delivery rate and origin"><SaveForm table="program_settings" rowKey="current" testId="delivery" fields={fieldsFrom(s.program, ['delivery_per_km_cents', 'delivery_min_cents', 'delivery_max_cents', 'delivery_round_cents', 'company_latitude', 'company_longitude', 'company_address'])} /></Card> },
      insurers: { table: 'insurers', key: 'id', rows: s.insurers, fields: (r) => [{ name: 'name', label: 'Name', required: true, value: r.name }, { name: 'billing_contact_name', label: 'Billing contact', value: r.billing_contact_name }, { name: 'billing_email', label: 'Billing email', type: 'email', value: r.billing_email }, { name: 'billing_phone', label: 'Billing phone', type: 'tel', value: r.billing_phone }, { name: 'billing_address', label: 'Billing address', value: r.billing_address }, { name: 'notes', label: 'Notes', type: 'textarea', value: r.notes }, { name: 'is_active', label: 'Active', type: 'bool', value: r.is_active ?? true }] },
      'promo-codes': { table: 'promo_codes', key: 'id', rows: s.promo_codes, fields: (r) => [{ name: 'code', label: 'Code', required: true, value: r.code }, { name: 'description', label: 'Description', value: r.description }, { name: 'percent_bps', label: 'Percent off the rental', type: 'percent', value: r.percent_bps }, { name: 'amount_cents', label: 'or amount off', type: 'money', value: r.amount_cents }, { name: 'valid_from', label: 'Valid from', type: 'datetime', value: r.valid_from }, { name: 'valid_until', label: 'Valid until', type: 'datetime', value: r.valid_until }, { name: 'max_uses', label: 'Maximum uses', type: 'number', value: r.max_uses }, { name: 'once_per_renter', label: 'Once per renter', type: 'bool', value: r.once_per_renter ?? true }, { name: 'is_active', label: 'Active', type: 'bool', value: r.is_active ?? true }] },
      'quick-replies': { table: 'quick_replies', key: 'id', rows: s.quick_replies, fields: (r) => [{ name: 'title', label: 'Title', required: true, value: r.title }, { name: 'body', label: 'Text', type: 'textarea', required: true, value: r.body }, { name: 'category', label: 'Category', value: r.category }, { name: 'is_active', label: 'Active', type: 'bool', value: r.is_active ?? true }] }
    };
    const c = cfg[section]!;
    return (<>{head}
      {c.extra}
      <Card title={`${c.rows.length} on file`}>{c.rows.length ? c.rows.map((r) => (
        <details key={String(r[c.key])}><summary className="link">{String(r.label ?? r.name ?? r.code ?? r.title ?? (section === 'deposits' ? $(r.amount_cents) : `${String(r.km_per_day)} km`))}{r.is_active === false ? ' (off)' : ''}{r.uses !== undefined ? ` · ${String(r.uses)} uses` : ''}{r.unpaid_cents !== undefined ? ` · ${String(r.open_bookings)} open bookings, ${$(r.unpaid_cents)} unpaid` : ''}</summary>
          <SaveForm table={c.table} rowKey={String(r[c.key])} compact fields={c.fields(r)} /></details>)) : <p className="small muted">None yet.</p>}</Card>
      <Card title="Add"><SaveForm table={c.table} label="Add" testId={`add-${section}`} fields={c.fields({})} /></Card>
    </>);
  }
  case 'coverage':
    return (<>{head}
      <p className="small muted">A price by car wins over a price by class. Empty table: coverage is priced in each offer.</p>
      <Card title="Prices in force"><Table rows={s.coverage} empty="No prices yet." cols={[{ key: 'class_code', label: 'Class' }, { key: 'vehicle_name', label: 'Car' }, { key: 'age_band', label: 'Age band' }, { key: 'amount_cents', label: 'Price', num: true, render: (r) => $(r.amount_cents) }, { key: 'per_day', label: 'Per day', render: (r) => yes(r.per_day) }, { key: 'effective_from', label: 'From', render: (r) => d(r.effective_from) }]} /></Card>
      <Card title="Add a price"><SaveForm table="coverage_prices" label="Add" fields={[{ name: 'class_code', label: 'Class', type: 'select', options: classOpts }, { name: 'vehicle_id', label: 'or vehicle id' }, { name: 'age_band', label: 'Age band', type: 'select', required: true, options: [['18_to_20', '18 to 20'], ['21_to_25', '21 to 25'], ['26_plus', '26 and over']] }, { name: 'amount_cents', label: 'Price', type: 'money', required: true }, { name: 'per_day', label: 'Per day', type: 'bool', value: true }, { name: 'effective_from', label: 'From', type: 'date' }, { name: 'note', label: 'Note' }]} /></Card>
      {s.coverage.length > 0 && <Card title="Change a price">{s.coverage.map((r) => <details key={String(r.id)}><summary className="link">{String(r.class_code ?? r.vehicle_name)} · {label(r.age_band)} · {$(r.amount_cents)}</summary><SaveForm table="coverage_prices" rowKey={String(r.id)} compact fields={[{ name: 'amount_cents', label: 'Price', type: 'money', value: r.amount_cents }, { name: 'effective_to', label: 'Ends on', type: 'date', value: r.effective_to }]} /></details>)}</Card>}
    </>);
  case 'email':
    return (<>{head}
      <Card title="Sending addresses">{s.email_aliases.map((r) => <details key={String(r.address)}><summary className="link">{String(r.address)} · {String(r.purpose)}{r.is_active === false ? ' (off)' : ''}</summary><SaveForm table="email_aliases" rowKey={String(r.address)} compact fields={[{ name: 'purpose', label: 'Purpose', value: r.purpose }, { name: 'is_active', label: 'Active', type: 'bool', value: r.is_active }]} /></details>)}
        <SaveForm table="email_aliases" label="Add an address" fields={[{ name: 'address', label: 'Address', type: 'email', required: true }, { name: 'purpose', label: 'Purpose', required: true }]} /></Card>
      <Card title="Where replies go"><Table rows={s.reply_to} cols={[{ key: 'audience', label: 'Audience', render: (r) => r.audience ? String(r.audience) : 'any' }, { key: 'code', label: 'Email', render: (r) => r.code ? String(r.code) : 'any' }, { key: 'reply_to', label: 'Reply to' }, { key: 'note', label: 'Note' }]} />
        {s.reply_to.map((r) => <details key={String(r.id)}><summary className="link">Change {String(r.audience ?? 'any')} / {String(r.code ?? 'any')}</summary><SaveForm table="email_reply_to" rowKey={String(r.id)} compact fields={[{ name: 'reply_to', label: 'Reply to', type: 'email', value: r.reply_to }, { name: 'note', label: 'Note', value: r.note }]} /></details>)}
        <SaveForm table="email_reply_to" label="Add a rule" fields={[{ name: 'audience', label: 'Audience', type: 'select', options: [['renter', 'Renter'], ['owner', 'Owner'], ['staff', 'Staff'], ['insurer', 'Insurer']] }, { name: 'code', label: 'Email code (empty: any)' }, { name: 'reply_to', label: 'Reply to', type: 'email', required: true }]} /></Card>
      <p className="small"><Link prefetch={false} className="link" href="/admin/messages">Outbox and suppressions</Link></p>
    </>);
  case 'staff':
    return (<>{head}
      <Card title="Invite"><p className="small muted">An invitation email with a link to choose a password (24 hours), then their portal. Owners and investors on file are invited from <Link prefetch={false} className="link" href="/admin/portals#invite">Admin &gt; Portals</Link>. Admin access is only through the addresses under Admin access below.</p><InviteForm roles={['va', 'field']} testId="staff-invite" /></Card>
      {await (async () => {
        const acc = await door<{ allowed: string[]; test: string[]; holders: Array<{ email: string; name: string | null; allowed: boolean; test: boolean }> }>(user.id, 'ops_read', 'admin_access').catch(() => null);
        if (!acc) return null;
        return (
          <Card title="Admin access" testId="admin-access">
            <p className="small">Only these addresses can hold the Admin role. The database refuses it for anyone else, and invitations do not offer it.</p>
            <AdminAccessForm allowed={acc.allowed} />
            <p className="small muted">Automated test account: {acc.test.join(', ')}. The live verification (the verify workflow) signs in with it to check the Admin pages; it is on the email suppression list and its password is scrambled after each run. It is not a person and cannot be removed here.</p>
            <ul className="ad-list" data-testid="admin-holders">{acc.holders.map((h) => <li key={h.email}><span>{h.email}{h.name ? ` (${h.name})` : ''}</span><span className="small">{h.test ? 'automated test account' : h.allowed ? 'allowed' : 'not on the list'}</span></li>)}</ul>
          </Card>);
      })()}
      <Card title="Staff"><Table rows={s.staff} testId="staff" cols={[{ key: 'full_name', label: 'Name' }, { key: 'email', label: 'Email' }, { key: 'roles', label: 'Roles', render: (r) => (r.roles as string[] | null)?.join(', ') },
        { key: 'fn', label: 'Function', render: (r) => { const p = r.profile as R | null; if (!p) return ''; const cover = (p.cover_functions as string[] | null) ?? []; return `${label(p.va_function ?? p.field_function)}${cover.length ? ` (also ${cover.map(label).join(', ')})` : ''}`; } }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'last_sign_in_at', label: 'Last sign-in', render: (r) => t(r.last_sign_in_at) },
        { key: 'limits', label: 'Limits', render: (r) => { const p = r.profile as R | null; return p ? `${$(p.single_limit_cents)} / ${$(p.dual_approval_threshold_cents)}` : ''; } },
        { key: 'act', label: 'Actions', render: (r) => r.id === user.id ? <span className="muted small">you</span> : <span className="ad-actions">
          {r.status === 'active' && <PasswordLinkButton userId={String(r.id)} testId={`pw-${String(r.email)}`} />}
          {r.status === 'active' && [String((r.profile as R | null)?.va_function ?? ''), ...(((r.profile as R | null)?.cover_functions as string[] | null) ?? [])].filter((f) => f && (r.profile as R | null)?.staff_type === 'va')
            .map((f) => <ViewAsButton key={f} user={String(r.id)} portal="va" fn={f} label={`View as (${label(f)})`} testId={`view-as-${String(r.email)}-${f}`} />)}
          {r.status === 'active' && (r.profile as R | null)?.staff_type === 'field' && <ViewAsButton user={String(r.id)} portal="field" testId={`view-as-${String(r.email)}-field`} />}
          {(r.profile as R | null) && <SaveFormLimits id={String(r.id)} p={r.profile as R} />}
          {(r.profile as R | null)?.va_function ? <>
            <Link prefetch={false} className="link small" href={`/admin/staff/${String(r.id)}/scorecard`}>Scorecard</Link>
            <Act action="staff_cover" payload={{ user: r.id }} label="Covers" testId={`cover-${String(r.id)}`} refresh={['/admin/settings/staff']} fields={[{ name: 'functions', label: 'Also covers (finance, fleet, cs, sales; comma separated)', type: 'list',
              value: ((r.profile as R).cover_functions as string[] | null) ?? [] }]} /></> : null}
          {r.status === 'active' ? <Act action="staff_end" payload={{ user: r.id }} label="End access" variant="danger" confirm={`End ${String(r.full_name)}'s access now? The staff portal closes to them at once.`} refresh={['/admin/settings/staff']} />
            : <Act action="staff_restore" payload={{ user: r.id }} label="Restore" refresh={['/admin/settings/staff']} />}</span> }]} /></Card>
      <Card title="Staff agreements" testId="staff-agreements"><StaffAgreements rows={await door<StaffAgreementRow[]>(user.id, 'ops_read', 'staff_agreements', {}).catch(() => [])} today={new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date())} /></Card>
    </>);
  }
  notFound();
}

function SaveFormLimits({ id, p }: { id: string; p: R }) {
  return <details><summary className="link small">Limits</summary><SaveForm table="staff_profiles" rowKey={id} compact fields={[{ name: 'single_limit_cents', label: 'Single limit', type: 'money', value: p.single_limit_cents }, { name: 'dual_approval_threshold_cents', label: 'Second approval above', type: 'money', value: p.dual_approval_threshold_cents }]} /></details>;
}
