import { AutoReplies } from '@/features/auto-reply/AutoReplies';
import { SceneReferences } from '@/features/listing/Marketing';
import { StaffOnboarding } from '@/features/staff-onboarding/StaffOnboarding';
import type { ApprovalRow, OnboardingRow } from '@/features/staff-onboarding/model';
import { OnboardingApprovals } from '@/features/staff-onboarding/Approvals';
import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act, SaveForm, type Field } from '@/features/admin/Act';
import { fieldsFrom } from '@/features/admin/fields';
import { LogoUpload } from '@/features/admin/SettingsClient';
import { InviteForm, PasswordLinkButton } from '@/features/admin/AccountTools';
import { ViewAsButton } from '@/features/admin/ViewAs';
import { $, Badge, Card, Kv, PageHead, Table, d, t, label } from '@/features/admin/ui';
import { SampleCarsToggle } from '@/features/supply/SampleCarsToggle';
import { SECTIONS } from '../sections';
import { rpc } from '@/lib/db/repo';
import { ApiAccessPage } from '@/features/api-access/ApiAccessPage';
import { door } from '@/server/door';
import { OfficialForms, type FormsData } from '@/features/official-forms/OfficialForms';
import { RentalForms, type RentalForm } from '@/features/blindspot/RentalForms';
import { AgreementGate, type AgreementGateRow } from '@/features/manual/AgreementGate';
import { StaffAgreements, type StaffAgreementRow } from '@/features/manual/StaffAgreements';
import { AdminAccessForm, SampleRowActions, SampleThumb, SampleUpload } from '@/features/admin/SamplePhotosClient';
import { StaffDefaults, type StaffDefaultsValue } from '@/features/admin/StaffDefaults';
import { GameSettings, type CostBasis, type Prize } from '@/features/games/GameSettings';
import { GameReportTiles, type GameReport } from '@/features/games/GameLeads';
import { GateReport, GateSwitches, type GateReportData } from '@/features/phone-gate/GateReport';
import { ArticleEditor, BusinessListings, PageEditor, type ArticleRow, type Listing, type PageRow } from '@/features/seo/SeoAdmin';
import { AddonsAdmin, type AddonsData } from '@/features/addons/AddonsAdmin';
import { VehiclePagesAdmin, type VpData } from '@/features/vehicles/VehiclePagesAdmin';
import { StockPhotosAdmin, type StockData } from '@/features/vehicles/StockPhotosAdmin';
import { ClassRules, type ClassRulesData } from '@/features/vehicles/ClassRules';
import { MaintenanceSettings, type MaintSettings } from '@/features/maintenance/Settings';
import { TextAlertsSettings, type SmsSettings } from '@/features/admin/TextAlerts';
import { SalesSettings } from '@/features/sales-leads/SalesSettings';
import type { LeadSettings } from '@/features/sales-leads/model';
import { PlaceRegions, PlaceSettings, PlaceTerms, type PlacesOverview } from '@/features/places/PlacesAdmin';
import { COVERAGE_LABEL, NETWORK_LABEL, VEHICLE_TYPE_LABEL, YES_NO_LABEL, type CardList, type CoverageKind } from '@/features/coverage/cards';
import { ReviewSettings, type ReviewSettingsData } from '@/features/reviews/ReviewSettings';
import { googleKeys } from '@/server/reviews/google';
import { SalesModesCard, type SalesModes } from '@/features/sales/SalesModesAdmin';
import { StaffFunctions } from '@/features/staff/StaffFunctions';
import { CardReaderAdmin, type TerminalState } from '@/features/terminal/CardReaderAdmin';
import { LeadTimeSettings } from '@/features/rates/LeadTimeEditor';
import { StuckReport, type StuckReportData } from '@/features/help/StuckReport';
import type { Tier } from '@/features/rates/lead-time';
import { profileFunctions as staffFns, STAFF_FN_LABEL } from '@/features/staff/nav';
const googleKeysSet = () => googleKeys() !== null;

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Settings', path: '/admin/settings', noindex: true, description: 'Settings.' });

type R = Record<string, unknown>;
type S = { site: R; program: R; program_rows: R[]; content: R[]; fee_types: R[]; fee_defaults: R[]; deposit_tiers: R[]; km_choices: R[]; classes: R[]; airports: R[]; coverage: R[];
  email_aliases: R[]; reply_to: R[]; insurers: R[]; promo_codes: R[]; promo_personal: R[]; promo_personal_count: number; quick_replies: R[]; staff: R[]; problems: Array<{ field: string; message: string }> };

const SITE_GROUPS: Array<[string, string[]]> = [
  ['Brand and tagline', ['brand_name', 'tagline', 'wordmark_text', 'logo_alt', 'logo_width', 'logo_height', 'site_url']],
  ['Contact', ['phone', 'phone_display', 'whatsapp', 'whatsapp_display', 'roadside_phone', 'roadside_phone_display', 'public_email', 'owners_email', 'mailing_address', 'street_address', 'show_street_address']],
  ['Hours and handover', ['opening_hours_text', 'handover_any_time', 'handover_slots', 'city', 'region', 'service_area', 'delivery_area_text', 'delivery_areas', 'airport_delivery']],
  ['Social, reviews and search', ['social_links', 'google_place_id', 'review_source', 'reply_wording', 'seo_default_title', 'seo_title_suffix', 'seo_default_description', 'listing_time_promise', 'featured_mode']],
  ['Search engines', ['google_site_verification', 'google_verification_file', 'bing_site_verification']],
  ['Email limit', ['email_limit_texts', 'email_limit_text_codes']],
  ['Deposit link by text', ['deposit_link_auto', 'deposit_link_hours']],
  ['Business name, address and phone', ['business_name', 'business_street', 'business_city', 'business_region', 'business_postal_code', 'business_latitude', 'business_longitude', 'business_categories', 'business_description']]
];
const PROGRAM_GROUPS: Array<[string, (k: string) => boolean]> = [
  ['Company', (k) => k.startsWith('company_') || ['incident_line_phone', 'privacy_officer_name', 'privacy_officer_email', 'signing_officer_name', 'signing_officer_title', 'signing_officer_authorized_on', 'timezone', 'hst_bps'].includes(k)],
  ['Booking requests and offers', (k) => /^(booking_|offer_|request_|max_|min_|standard_min|accepted_licence|other_licence|info_request|tentative|turnaround|non_refundable|verification|early_return|chase_|addon_|extension_|late_fee_)/.test(k)],
  ['Driver\'s licence reader', (k) => k.startsWith('licence_')],
  // 1402: the fuel shortfall at each return (update the pump prices weekly); 1400 and 1401: card coverage and OPCF 27
  ['Fuel and charging at the return', (k) => /^(fuel_price|fuel_prices_updated_on|refuel_fee_cents|ev_charge_kwh_cents|fuel_tank_default_litres|ev_battery_default_kwh)/.test(k)],
  ['Coverage checks', (k) => ['card_exotic_makes', 'opcf27_before_payment'].includes(k)],
  ['Owner debits and statement emails', (k) => /^(owner_debit_|billing_day|retry_day|owner_late_fee|owner_statement_email|company_statement_email)/.test(k)],
  ['Deposits, refunds and money', (k) => /^(deposit_|refund_|statement_|holdback|insurer_|liability|deductible|kickback|shareholder|install_fee|owner_late|billing_day|retry_day|payout_day|fleet_report_day|investor_|buyout|take_deposit)/.test(k)],
  ['Delivery', (k) => k.startsWith('delivery_') || ['company_latitude', 'company_longitude'].includes(k)],
  ['Maintenance', (k) => k.startsWith('maint_')],
  ['Owners and fleet', (k) => /^(notice_period|free_retransfer|owner_|retransfer|total_loss|min_fleet|fleet_warning|safety_|fee_change|trackers_available|tracker_|plate_renewal|turo_|provisional_)/.test(k)],
  ['Field jobs and handovers', (k) => k.startsWith('field_')],
  ['Tolls and damage', (k) => /^(toll_|damage_|incident_)/.test(k)],
  ['Listings', (k) => k.startsWith('listing_') || k.startsWith('photo_') || k.startsWith('plate_')],
  ['Vision model', (k) => k.startsWith('ai_vision')],
  ['Email and notifications', (k) => k.startsWith('notify_')],
  ['E-signing (every signature on the site)', (k) => k.startsWith('esign_')],
  ['Partners, rentals added by hand and agreements', (k) => /^(partner_|manual_rental_|staff_agreement_)/.test(k)],
  ['Staff commissions and prices typed by hand', (k) => /^(staff_commission_|sales_tier_|sales_remote_|custom_price_)/.test(k)],
  ['Referral partners (body shops, tow trucks)', (k) => k.startsWith('referral_partner_')],
  ['Advertising and owner recruitment', (k) => /^(ads_|recruit_)/.test(k)],
  ['AI auto-replies (FAQ answers by text, email, chat, WhatsApp, Messenger, Instagram)', (k) => k.startsWith('auto_reply_')],
  ['Live visitors and live chat', (k) => /^(visitor_|chat_)/.test(k)],
  ['The CarmaCars app (App Store and Google Play)', (k) => ['app_store_url', 'play_store_url'].includes(k)],
  ['Review requests', (k) => k.startsWith('review_')],
  ['Search copy, landing pages and reviews', (k) => /^(seo_|google_review_|indexnow_)/.test(k)],
  ['Vehicle pages', (k) => k.startsWith('vpage_')],
  ['Forms left unfinished (contact capture)', (k) => k.startsWith('capture_')],
  ['Promo codes', (k) => k.startsWith('promo_')],
  ['Discount games', (k) => k.startsWith('game_')],
  ['Phone number box', (k) => k.startsWith('phone_gate_')],
  ['Text alerts', (k) => k.startsWith('sms_')],
  ['Phone and texts (Quo)', (k) => k.startsWith('phone_')],
  ['Sign-in by phone', (k) => k.startsWith('signin_')],
  ['Google Maps daily caps', (k) => k.startsWith('maps_')],
  ['Facebook Marketplace', (k) => k.startsWith('marketplace_')],
  ['Stuck? help', (k) => k.startsWith('stuck_')],
  ['Photo import from Google Drive', (k) => k === 'google_drive_api_key'],
  // r35 UX (1108): how to pay on invoices (empty until entered), insurer invoices as Blind Spot Car Rental, add-ons not returned
  ['Invoices: how to pay CarmaCars (direct deposit and e-Transfer; empty sections are left off the PDF)', (k) => k.startsWith('cc_pay_')],
  ['Insurer invoices as Blind Spot Car Rental (name, contact, direct deposit and e-Transfer)', (k) => k.startsWith('bs_')],
  ['Add-ons not returned (the agreement\'s fine print, the FAQ and the deposit review\'s suggestion)', (k) => k.startsWith('unreturned_')],
  ['Staff, privacy and housekeeping', () => true]
];
const yes = (v: unknown) => (v ? 'Yes' : 'No');
type QuoStatus = { enabled: boolean; synced: number; waiting: number; errors: number; no_name: number; total: number; last_run_at: string | null; last_ok_at: string | null;
  last_result: Record<string, unknown> | null; last_error: string | null; last_error_at: string | null; paused_until: string | null; pause_reason: string | null;
  scan: { status: 'pending' | 'done'; seen: number; matched: number; done_at: string | null }; recent_errors: Array<Record<string, unknown>> };
// the reminders sent for a promo code ({"3d": time, "1d": time}), in words
const remindersText = (m: unknown) => {
  const x = (m ?? {}) as Record<string, string>;
  const sent = [x['3d'] ? `first ${d(x['3d'])}` : '', x['1d'] ? `day before ${d(x['1d'])}` : ''].filter(Boolean);
  return sent.length ? sent.join(', ') : 'none sent';
};
// a new promo code starts with an end date this many days ahead (Program settings, Promo codes)
const promoEnd = (program: R) => new Date(Date.now() + Number(program.promo_default_valid_days ?? 30) * 86400000).toISOString();
const PROMO_STATUS: Record<string, string> = { open: 'Open', on_request: 'On a booking request', used: 'Used', expired: 'Expired', off: 'Off' };
const PROMO_SOURCE: Record<string, string> = { discount_game: 'Discount game', followup_7d: 'Come-back, 1 week', followup_30d: 'Come-back, 1 month', live_visitors: 'Live visitors' };
// Settings > Promo codes: the rules, then the codes sent to people with their end dates and reminders
function PromoExtra({ s }: { s: S }) {
  return (<>
    <Card title="End dates and reminders" testId="promo-rules">
      <p className="small">A code for a person (a game prize, a come-back offer, a Live visitors code, or a code made for one renter) always has an end date and the person is reminded before it ends: once 3 days before its last day and once the day before, by email and by text as they chose, only while it is unused. Game codes keep their transactional reminder; every other code is an offer, so it needs the person&apos;s consent to offers. A code made for the public may have no end date.</p>
      <SaveForm table="program_settings" rowKey="current" testId="promo-rules-form" fields={fieldsFrom(s.program, ['promo_default_valid_days', 'promo_reminders_enabled', 'promo_reminder_3d_days', 'promo_reminder_1d_on', 'game_code_valid_days', 'notify_comeback_valid_days'])} />
    </Card>
    <Card title={`Codes sent to people (${s.promo_personal_count}${s.promo_personal_count > s.promo_personal.length ? `, the latest ${s.promo_personal.length}` : ''})`} testId="promo-personal">
      <Table rows={s.promo_personal} empty="None yet." cols={[
        { key: 'code', label: 'Code', render: (r) => String(r.code) },
        { key: 'source', label: 'From', render: (r) => PROMO_SOURCE[String(r.source)] ?? label(r.source) },
        { key: 'valid_until', label: 'Ends', render: (r) => d(r.valid_until) },
        { key: 'status', label: 'State', render: (r) => PROMO_STATUS[String(r.status)] ?? label(r.status) },
        { key: 'reminders', label: 'Reminders sent', render: (r) => remindersText(r.reminders) }]} />
    </Card>
  </>);
}

export default async function Section({ params, searchParams }: { params: Promise<{ section: string }>; searchParams?: Promise<Record<string, string | undefined>> }) {
  const { section } = await params;
  const meta = SECTIONS.find(([k]) => k === section);
  if (!meta) notFound();
  const { read, user } = await page(`/admin/settings/${section}`);
  const s = await read<S>('settings');
  const back = <Link prefetch={false} className="link" href="/admin/settings">Settings</Link>;
  const head = <PageHead kicker={back} title={meta[1]} />;
  const classOpts = (s.classes as Array<{ code: string; label: string; is_active?: boolean }>).filter((c) => c.is_active !== false).map((c) => [c.code, c.label] as [string, string]);
  // Admin > Staff: each person's academy progress (Release 21b, item 9)
  const academy = section === 'staff' ? new Map(((await door<{ staff: Array<{ id: string; passed: number; sections: number; done: boolean }> }>(user.id, 'admin_read', 'academy_progress').catch(() => null))?.staff ?? []).map((x) => [x.id, x])) : null;

  switch (section) {
  // release 28: API access (Claude connector and keys)
  case 'api': return (<>{head}<ApiAccessPage adminId={user.id} /></>);
  // r35 (0950): Settings > Sales, the lead claim rules
  case 'sales': return (<>{head}<SalesSettings s={await door<LeadSettings>(user.id, 'admin_read', 'sales_lead_settings')} /></>);
  case 'site': {
    const samples = await door<{ public: number; cars: number; catalogue: number; open_enquiries: number }>(user.id, 'ops_read', 'sample_cars_state').catch(() => null);
    return (<>{head}
      {s.problems.length > 0 && <Card title="Still missing" tone="warn"><ul className="small">{s.problems.map((p) => <li key={p.field}>{p.message}</li>)}</ul></Card>}
      {samples && <Card title="Sample cars" testId="site-sample-cars">
        <p className="small muted">The {samples.catalogue} example cars the site started with, so the fleet does not look empty while the real cars are listed. On the site they are marked &quot;Example car&quot;, stay out of search engines and the sitemap, and a request on one becomes an enquiry for customer service to suggest a similar real car (never a booking). Now {samples.public} on the site{samples.open_enquiries ? `, ${samples.open_enquiries} enquiries waiting` : ''}.</p>
        <SampleCarsToggle publicCount={samples.public} />
      </Card>}
      {SITE_GROUPS.map(([title, keys]) => <Card key={title} title={title}><SaveForm table="site_settings" rowKey="singleton" testId={`site-${title.split(' ')[0]!.toLowerCase()}`} fields={fieldsFrom(s.site, keys, { featured_mode: [['random', 'Random'], ['manual', 'Chosen by hand']] })} /></Card>)}
      <Card title="Logo"><p className="small muted">Light: {String(s.site.logo_light_file_key ?? 'none, the brand logo (black letters, red bar) is shown')}. Dark: {String(s.site.logo_dark_file_key ?? 'none, the brand logo (white letters, red bar) is shown')}. The logo shows in the site header and footer, every portal, every email (PNG or JPEG only; an SVG upload leaves emails on the brand logo) and on the documents (PNG or JPEG).</p><div className="ad-cols ad-cols--2"><LogoUpload which="light" /><LogoUpload which="dark" /></div></Card>
      <Card title="Search engines: how to verify" testId="search-verify"><ol className="small">
        <li>Google Search Console: add the property https://carmacars.ca, choose <b>HTML tag</b>, and paste only the content value (the part inside content=&quot;...&quot;) into Google site verification above. Or choose <b>HTML file</b> and type the file name (for example google1234abcd.html) into Google verification file: the site answers it at its root.</li>
        <li>Bing Webmaster Tools: import from Search Console, or choose the meta tag and paste its content into Bing site verification.</li>
        <li>Then submit the sitemap https://carmacars.ca/sitemap.xml in both. IndexNow tells Bing about changes by itself (key file: /{String(s.site.indexnow_key ?? '')}.txt).</li>
      </ol></Card>
      <Card title="Business listings" testId="business-listings-card">
        <BusinessListings listings={(s.site.business_listings ?? {}) as Record<string, Listing>} nap={[
          ['Name', String(s.site.business_name ?? s.site.brand_name ?? '')],
          ['Address', [s.site.business_street, [s.site.business_city, s.site.business_region].filter(Boolean).join(', ') + (s.site.business_postal_code ? ` ${String(s.site.business_postal_code)}` : '')].filter(Boolean).join(', ')],
          ['Phone', String(s.site.phone_display ?? s.site.phone ?? '')], ['Website', String(s.site.site_url ?? '')], ['Hours', String(s.site.opening_hours_text ?? '')],
          ['Categories', ((s.site.business_categories as string[] | null) ?? []).join(', ')], ['Description', String(s.site.business_description ?? '')]]} />
      </Card>
      <Card title="Browser icon and sharing image"><p className="small muted">Icon: {String(s.site.favicon_file_key ?? 'none, the brand icon (the CA mark) is shown')}. Sharing image: {String(s.site.og_image_file_key ?? 'none, the built-in image is used')}.</p><div className="ad-cols ad-cols--2"><LogoUpload which="favicon" /><LogoUpload which="og" /></div></Card>
    </>);
  }
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
  case 'maintenance':
    // the maintenance tracker (0089): items, intervals by class and car, service categories, reminders
    return (<>{head}<MaintenanceSettings s={await door<MaintSettings>(user.id, 'ops_read', 'maint_settings')} program={s.program} /></>);
  case 'addons': {
    // add-ons (0069): the catalogue, its prices and rules; Fleet sets stock from its own screen
    const data = await door<AddonsData>(user.id, 'ops_read', 'addons');
    return (<>{head}<AddonsAdmin data={data} /></>);
  }
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
  case 'vehicle-pages':
    return (<>{head}<VehiclePagesAdmin d={await door<VpData>(user.id, 'admin_read', 'vehicle_pages')} program={s.program} />
      {/* 0149: the licensed stock photos (empty until the migration and the first run) */}
      <StockPhotosAdmin d={await door<StockData>(user.id, 'admin_read', 'stock_photos').catch(() => ({ coverage: { models: 0, models_checked: 0, models_with_photo: 0, model_years: 0, model_years_with_photo: 0,
        generations: 0, model_only: 0, hidden: 0, pending: 0, failed: 0, generic: {}, popular: 0, popular_with_photo: 0, popular_missing: [], last_run: null }, photos: [] }))} /></>);
  case 'search': {
    type Ov = { cars: R[]; pages: Array<PageRow & R>; articles: Array<ArticleRow & R>; indexnow: { waiting: number; sent_7d: number; last: { at: string | null; status: number | null };
      answer?: IxAnswer; sweep?: IxAnswer & { next_round: string | null; streak_429: number } };
      neurons: { seo: number; all: number; seo_cap: number; all_cap: number }; min_real_cars: number };
    type Cov = Array<{ day: string; inspected: number; known?: number; indexed: number; crawled: number; discovered: number; unknown?: number; priority_inspected?: number; priority_indexed?: number }>;
    const [o, po, cov] = await Promise.all([door<Ov>(user.id, 'admin_read', 'seo_overview'), door<PlacesOverview>(user.id, 'admin_read', 'place_overview').catch(() => null),
      rpc('server_gsc_coverage_trend', { p_admin: user.id }, { role: 'service_role' }).then((x) => (x ?? []) as unknown as Cov).catch(() => [] as Cov)]);
    const pc = (n: number, of: number) => (of ? `${Math.round((n / of) * 100)}%` : '');
    return (<>{head}
      <p className="small muted">The car pages, the landing pages and the guides are written by the daily Claude batch (docs/seo-batches.md; Workers AI only when its writer is on in Program settings) from the facts in the database, checked (lengths, the house style, no number or claim the facts do not support) and published by themselves. Nothing waits for review. A field you change is locked and kept by every rewrite.</p>
      <Card title="Today" testId="seo-today"><Kv rows={[['Workers AI used for search copy', `${o.neurons.seo} of ${o.neurons.seo_cap} neurons`], ['All Workers AI use today', `${o.neurons.all} of ${o.neurons.all_cap} neurons`],
        ['IndexNow', `${o.indexnow.waiting} addresses waiting, ${o.indexnow.sent_7d} sent in 7 days${o.indexnow.last?.at ? `, last ${t(o.indexnow.last.at)} (${String(o.indexnow.last.status ?? '')})` : ''}`],
        // R23 (0220): the changed pages and the sweep each with their last answer and back-off
        ['IndexNow: changed pages', <span key="ixq" data-testid="seo-indexnow-answer">{ixLine(o.indexnow.answer, t)}</span>],
        ['IndexNow: sweep', <span key="ixs" data-testid="seo-indexnow-sweep">{ixLine(o.indexnow.sweep, t)}{o.indexnow.sweep?.next_round ? `; next round ${t(o.indexnow.sweep.next_round)}` : ''}</span>],
        ['Landing pages', 'every page is indexed and filled with its own data (release 35)']]} /></Card>
      {/* release 28 (0564): the gsc workflow's sample of addresses inspected in Search Console, by day */}
      <Card title="Index coverage (Search Console sample)" testId="seo-coverage">
        {/* 1103: indexed of the addresses Google knows (Search Console's own count), the priority part, and the long tail's unknown ones apart */}
        {cov.length ? <Table rows={cov as unknown as R[]} rowKey={(r) => String(r.day)} cols={[{ key: 'day', label: 'Day', render: (r) => String(r.day) }, { key: 'inspected', label: 'Inspected', num: true },
          { key: 'known', label: 'Known to Google', num: true, render: (r) => String(r.known ?? r.inspected) },
          { key: 'indexed', label: 'Indexed (of known)', render: (r) => `${String(r.indexed)} (${pc(Number(r.indexed), Number(r.known ?? r.inspected))})` },
          { key: 'priority_indexed', label: 'Priority pages indexed', render: (r) => (Number(r.priority_inspected ?? 0) ? `${String(r.priority_indexed)} of ${String(r.priority_inspected)} (${pc(Number(r.priority_indexed), Number(r.priority_inspected))})` : '') },
          { key: 'crawled', label: 'Crawled, not indexed', render: (r) => `${String(r.crawled)} (${pc(Number(r.crawled), Number(r.known ?? r.inspected))})` },
          { key: 'discovered', label: 'Discovered, not indexed', render: (r) => `${String(r.discovered)} (${pc(Number(r.discovered), Number(r.known ?? r.inspected))})` },
          { key: 'unknown', label: 'Unknown to Google', num: true, render: (r) => String(r.unknown ?? '') }]} />
          : <p className="small muted">No sample yet: the gsc workflow inspects about 150 addresses each run (every three hours) once migration 0564 is live.</p>}
      </Card>
      <Card title={`Car copy (${o.cars.length} real cars)`} testId="seo-cars"><Table rows={o.cars} rowKey={(r) => String(r.vehicle_id)} empty="No real car yet. Sample cars keep their sample text." cols={[
        { key: 'vehicle', label: 'Car', render: (r) => <Link prefetch={false} className="link" href={`/admin/vehicles/${String(r.vehicle_id)}?tab=listing`}>{String(r.vehicle)}</Link> },
        { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'source', label: 'Written by', render: (r) => (r.source === 'ai' ? 'Workers AI' : r.source === 'claude-batch' ? 'Daily Claude batch' : 'Plain copy (waiting)') },
        { key: 'h1', label: 'Heading', render: (r) => String(r.h1 ?? '') }, { key: 'published_at', label: 'Published', render: (r) => t(r.published_at) },
        { key: 'locked', label: 'Locked', render: (r) => ((r.locked as string[]) ?? []).join(', ') }, { key: 'up', label: 'Facts', render: (r) => (r.up_to_date ? 'Up to date' : 'Changed: rewriting') }]} /></Card>
      <Card title={`Landing pages (${o.pages.length})`} testId="seo-pages">
        <Table rows={o.pages as unknown as R[]} rowKey={(r) => String(r.slug)} cols={[
          { key: 'name', label: 'Page', render: (r) => <a className="link" href={String(r.path)} target="_blank" rel="noopener">{String(r.name)}</a> }, { key: 'kind', label: 'Kind', render: (r) => (r.kind === 'location' ? 'Place' : 'Use') },
          { key: 'indexable', label: 'In search', render: (r) => (r.indexable ? 'Yes' : 'No: switched off') }, { key: 'car_count', label: 'Cars', num: true },
          { key: 'source', label: 'Written by', render: (r) => ({ seed: 'Launch copy', ai: 'Workers AI', staff: 'An Admin' } as Record<string, string>)[String(r.source)] ?? String(r.source) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }]} />
        {o.pages.map((p) => <details key={p.slug}><summary className="link">Edit {p.name}</summary><PageEditor p={p} /></details>)}
      </Card>
      <Card title={`Guides (${o.articles.length})`} testId="seo-articles">
        <Table rows={o.articles as unknown as R[]} rowKey={(r) => String(r.slug)} cols={[
          { key: 'title', label: 'Guide', render: (r) => <a className="link" href={String(r.path)} target="_blank" rel="noopener">{String(r.title)}</a> }, { key: 'is_published', label: 'Published', render: (r) => yes(r.is_published) },
          { key: 'source', label: 'Written by', render: (r) => ({ seed: 'Launch copy', ai: 'Workers AI', staff: 'An Admin' } as Record<string, string>)[String(r.source)] ?? String(r.source) }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> },
          { key: 'content_updated_at', label: 'Updated', render: (r) => t(r.content_updated_at) }]} />
        {o.articles.map((a) => <details key={a.slug}><summary className="link">Edit {a.title}</summary><ArticleEditor a={a} /></details>)}
      </Card>
      {po && <>
        <Card title="Place pages" testId="seo-places"><PlaceSettings o={po} /></Card>
        <Card title="Regions and places" testId="seo-regions"><PlaceRegions o={po} /></Card>
        <Card title={`Terms and services (${po.terms.length} terms)`} testId="seo-terms"><PlaceTerms o={po} /></Card>
      </>}
    </>);
  }
  case 'phone-gate': {
    // the phone number box (0280): light by default (more photos and the full availability on, the request and the code off)
    const g = await door<GateReportData>(user.id, 'admin_read', 'phone_gate_report', { days: 30 });
    const keys = ['phone_gate_gallery', 'phone_gate_free_photos', 'phone_gate_dates', 'phone_gate_request', 'phone_gate_verify', 'phone_gate_allow_unverified',
      'phone_gate_texts_per_number_day', 'phone_gate_texts_per_ip_day', 'phone_gate_texts_per_day'];
    return (<>{head}
      <p className="small muted">A visitor who has not given a mobile number on this device is asked for one before more than the first {String(s.program.phone_gate_free_photos ?? 4)} photos of a car, and before the full availability (the booked days on a car&apos;s calendar, and the cars booked for the chosen dates). Picking dates and seeing whether that car is free stays open, and search engines see every photo. Signed-in renters with a verified mobile, and devices that gave a number in the last 90 days, never see it. Numbers given are under <Link prefetch={false} className="link" href="/admin/renters?tab=leads">People &gt; Renters &gt; Leads</Link> and on Live visitors.</p>
      <Card title="Each box, one press"><GateSwitches r={g.rules} /></Card>
      <GateReport g={g} />
      <Card title="All the settings" testId="gate-settings"><SaveForm table="program_settings" rowKey="current" testId="program-phone-gate" fields={fieldsFrom(s.program, keys)} /></Card>
    </>);
  }
  case 'discount-games': {
    // the giveaway game (0069): on by default with the owner's settings; everything here is optional to change
    const r = await door<GameReport>(user.id, 'admin_read', 'game_report', { days: 30 });
    const keys = ['game_enabled', 'game_max_discount_cents', 'game_code_valid_days', 'game_trigger_car_pages', 'game_trigger_seconds', 'game_exit_intent', 'game_reshow_car_pages', 'game_reshow_seconds',
      'game_max_per_visit', 'game_visit_gap_minutes', 'game_max_per_day', 'game_booking_offer', 'game_dismiss_days', 'game_replay_after_claim_days', 'game_saved_again_days', 'game_task_min_cars'];
    return (<>{head}
      <p className="small muted">Visitors who are not signed in get one quick game on their 2nd page view or after 30 seconds, whichever first: spin the wheel, scratch to reveal, quick blackjack, cup shuffle, Plinko, the card pack, coin flip, dice roll, slot machine, prize drop or mystery box. At most one game a visit (a setting), and it comes back on every new visit: a visit ends after 30 minutes away (a setting), also when they closed it without playing. With more than one a visit, another game (never the same one twice in a row) comes back on the 3rd page view after the close or 2 minutes later. After claiming a code, no game for the rest of that visit; a day later (a setting) the game comes back on their next visit and they can win another code. No games once a booking request is in progress, and never on booking, checkout or payment pages: the request-to-book form offers its own game to anyone who has not claimed in the last day, signed-in renters too. Every play wins a promo code for the rental charge, or another go (Play again: a second, different game that always ends in a code); the prize shows only as the game&apos;s outcome. A prize won and not claimed shows as a small &quot;Your 5% off is saved&quot; badge, and pops up again once a visit as a small slide-in (&quot;Your 5% off is still waiting&quot;) with Get my code and Play again: a new game, and they keep the better of the two prizes (once a day, a setting), until it is claimed or the visitor&apos;s prize ends. To see the code they give a first name and an email (a mobile number is optional), and the code is emailed. It is on now; nothing needs setting up. Leads are under <Link prefetch={false} className="link" href="/admin/leads">Bookings &gt; Renter leads</Link>.</p>
      <Card title="See it yourself" testId="game-preview"><p className="small">Open the site with the game on screen at once, signed in or not. A preview plays a game through to a sample prize: no code is made and nothing is recorded or remembered.</p>
        <p><a className="btn btn--primary btn--sm" href="/?preview=game" target="_blank" rel="noopener" data-testid="game-preview-link">Preview the game</a></p></Card>
      <Card title="On or off and the rules" testId="game-rules"><SaveForm table="program_settings" rowKey="current" testId="program-games" fields={fieldsFrom(s.program, keys)} /></Card>
      <Card title="Prizes and games"><GameSettings prizes={(s.program.game_prizes ?? []) as Prize[]} weights={(s.program.game_weights ?? {}) as Record<string, number>}
        cap={s.program.game_max_discount_cents == null || s.program.game_max_discount_cents === '' ? null : Number(s.program.game_max_discount_cents)} basis={(r as GameReport & { cost_basis?: CostBasis }).cost_basis ?? null} /></Card>
      <Card title="Last 30 days"><GameReportTiles r={r} /></Card>
    </>);
  }
  case 'reviews': {
    // review requests (0146): the timings and the hold, the Google review link, and the Google Business Profile connection
    const keys = ['review_program_enabled', 'review_checkin_enabled', 'review_preask_enabled', 'review_preask_days_before', 'review_checkin_min_days', 'review_checkin_after_hours', 'review_ask_after_minutes', 'review_reminder_hours',
      'review_final_days', 'review_send_from_hour', 'review_send_until_hour', 'review_hold_incidentals', 'review_ask_max_days', 'review_google_match_days', 'review_google_auto_match'];
    const [r, sp] = await Promise.all([door<ReviewSettingsData>(user.id, 'admin_read', 'review_settings'), searchParams ?? Promise.resolve({} as Record<string, string | undefined>)]);
    return (<>{head}
      <ReviewSettings data={r} message={sp.google ?? null} keysSet={googleKeysSet()}
        timings={<SaveForm table="program_settings" rowKey="current" testId="program-reviews" fields={fieldsFrom(s.program, keys)} />}
        link={<SaveForm table="site_settings" rowKey="singleton" testId="site-reviews" fields={fieldsFrom(s.site, ['google_place_id', 'google_review_link'])} />} /></>);
  }
  case 'quo-contacts': {
    // Quo contacts (0190): every person on the site with a phone number is a contact in Quo, kept in step by the job
    const q = await door<QuoStatus>(user.id, 'admin_read', 'quo_contacts_status');
    const res = (q.last_result ?? {}) as Record<string, unknown>;
    const lastRun = q.last_run_at ? `${t(q.last_run_at)}: ${Number(res.created ?? 0)} created, ${Number(res.updated ?? 0)} updated, ${Number(res.failed ?? 0)} failed` : 'Not run yet';
    return (<>{head}
      <Card title="Contacts in Quo" testId="quo-contacts">
        <p className="small">Everyone on the site with a phone number (staff, renters and their drivers, owners, partners, investors, referral partners, job applicants, named visitors, leads, chauffeur clients, live chats, game players and forms left unfinished) is a contact in the CarmaCars Quo workspace under the same name, with their email and company. A new person is added within about five minutes, and a changed name, phone or email is updated the same way. When two records share a number, the strongest one names the contact: staff, then a renter, a driver, an owner. A contact someone already made in Quo for the number is updated rather than made twice, and the other numbers and emails on it are kept. If Quo is down, bookings go on and the contacts follow when it is back.</p>
        <div className="ad-tiles">
          <div className="ad-tile"><span className="ad-tile__k">In Quo</span><b className="ad-tile__v" data-testid="quo-synced">{q.synced}</b><span className="ad-tile__s">up to date</span></div>
          <div className="ad-tile"><span className="ad-tile__k">Waiting</span><b className="ad-tile__v" data-testid="quo-waiting">{q.waiting}</b><span className="ad-tile__s">go with the next run</span></div>
          <div className="ad-tile"><span className="ad-tile__k">Errors</span><b className="ad-tile__v" data-testid="quo-errors">{q.errors}</b><span className="ad-tile__s">tried again later</span></div>
          <div className="ad-tile"><span className="ad-tile__k">No name</span><b className="ad-tile__v">{q.no_name}</b><span className="ad-tile__s">numbers without a name are not sent</span></div>
        </div>
        <Kv rows={[
          ['Sync', q.enabled ? 'On' : 'Off (Program settings, Phone and texts)'],
          ['Last run', lastRun],
          ['Last good run', q.last_ok_at ? t(q.last_ok_at) : 'None yet'],
          ['Paused', q.paused_until ? `${q.pause_reason ?? 'Paused'}, until ${t(q.paused_until)}` : null],
          ['Last error', q.last_error ? `${q.last_error}${q.last_error_at ? ` (${t(q.last_error_at)})` : ''}` : 'None'],
          ['Quo\'s own contacts', q.scan.status === 'done' ? `Read ${q.scan.done_at ? t(q.scan.done_at) : ''}: ${q.scan.seen} contacts, ${q.scan.matched} already had a number of ours` : `Being read: ${q.scan.seen} so far`]
        ]} />
        <Act action="quo_contacts_resync" label="Sync everyone again" variant="ghost" testId="quo-resync" done="Everyone is sent again, starting with the next run."
          confirm="Every person with a phone number is sent to Quo again, after Quo's contact list is read again. Nobody is added twice." />
      </Card>
      <Card title="Recent errors">
        <Table rows={q.recent_errors as unknown as R[]} empty="No errors." cols={[
          { key: 'number', label: 'Number', render: (r) => String(r.number) },
          { key: 'name', label: 'Name', render: (r) => String(r.name ?? '') },
          { key: 'error', label: 'Error', render: (r) => String(r.error ?? '') },
          { key: 'at', label: 'When', render: (r) => t(r.at) },
          { key: 'retry_at', label: 'Next try', render: (r) => (r.retry_at ? t(r.retry_at) : 'After the next change') }]} />
      </Card>
    </>);
  }
  case 'text-alerts': {
    // text alerts (0096): the defaults and quiet hours, and the text of each notification
    const keys = ['sms_alerts_enabled', 'push_enabled', 'sms_default_with_phone', 'sms_default_phone_only', 'sms_quiet_hours', 'sms_quiet_from_hour', 'sms_quiet_until_hour', 'sms_stop_line', 'sms_generic_text', 'signin_phone_us_allowed'];
    const ch: Array<[string, string]> = [['both', 'Both'], ['text', 'Text'], ['email', 'Email']];
    // the messages of a booking's start and end (0430): one switch per moment, all on
    const moments = ['notify_pickup_soon', 'notify_pickup_soon_hours', 'notify_trip_started', 'notify_return_soon', 'notify_return_soon_hours', 'notify_return_due',
      'notify_late_auto', 'notify_late_first_minutes', 'notify_renter_from_hour', 'notify_renter_until_hour', 'notify_pickup_unrecorded',
      'notify_pickup_unrecorded_minutes', 'notify_pickup_unrecorded_admin_minutes', 'notify_not_back', 'notify_not_back_minutes'];
    // staff alerts for leads and visitors (0460): in the app and on the phone, one switch each, all on
    const leadAlerts = ['notify_lead_new', 'notify_request_unfinished', 'notify_owner_lead_new', 'notify_hot_visitor', 'notify_lead_burst_count', 'notify_lead_burst_minutes',
      'alert_money_threshold_cents', 'alert_escalate_enabled', 'alert_escalate_minutes', 'alert_brief_enabled', 'alert_burst_count', 'alert_burst_minutes', 'alert_complaint_words',
      'app_store_url', 'play_store_url'];
    return (<>{head}<TextAlertsSettings data={await door<SmsSettings>(user.id, 'admin_read', 'sms_settings')}
      form={<SaveForm table="program_settings" rowKey="current" testId="program-sms" fields={fieldsFrom(s.program, keys, { sms_default_with_phone: ch, sms_default_phone_only: ch.slice(0, 2) })} />} />
      <Card title="Booking start and end" testId="sms-moments">
        <p className="small muted">What the renter gets, by email, text and phone alert: the day before pickup, about 2 hours before, &quot;you&apos;re all set&quot; if nobody recorded the pickup, the day before the return, about 3 hours before, at the return time, then T13 at 15 minutes and T14 at 2 hours late. A booking whose pickup was not recorded counts as out, so it gets all of them. Staff get the pickup not recorded and not back alerts. Each is sent once, and again only when the time changes.</p>
        <SaveForm table="program_settings" rowKey="current" testId="program-moments" fields={fieldsFrom(s.program, moments)} />
      </Card>
      <Card title="Staff alerts" testId="sms-lead-alerts">
        <p className="small muted">In the app and on the phone (never email, never text): a new renter lead, a request typed and not sent, a new owner lead and a visitor turning Hot. The Admins always get them; so does the person a lead is assigned to, else customer service and Sales on duty. Each person turns the Leads and Visitors topics on or off per device on their alerts card. More than the number below in the window become one &quot;N new leads&quot; alert. Every other staff alert (each one on or off, its tier) is on <Link prefetch={false} className="link" href="/admin/alerts?tab=settings#rules">Alerts &gt; Settings</Link>.</p>
        <SaveForm table="program_settings" rowKey="current" testId="program-lead-alerts" fields={fieldsFrom(s.program, leadAlerts)} />
      </Card></>);
  }
  case 'card-reader': return (<>{head}<CardReaderAdmin s={await door<TerminalState>(user.id, 'ops_read', 'terminal_state')} /></>);
  case 'class-rules': return (<>{head}<ClassRules data={await door<ClassRulesData>(user.id, 'ops_read', 'class_rules')} /></>);
  case 'forms': {
    // the registry forms, then the forms filled for every booking (0127: Blind Spot's rental agreement)
    const d = await door<FormsData & { rental_forms?: RentalForm[] }>(user.id, 'ops_read', 'form_templates');
    return (<>{head}<RentalForms forms={d.rental_forms ?? []} /><OfficialForms d={d} /></>);
  }
  case 'program': {
    // turnaround_block_minutes always equals the turnaround (0042): one setting is shown; owner_debit_show_legal_name is no
    // longer used (0122: the payee is always the legal name alone)
    // staff_agreement_defaults has its own form below, by function (0057)
    // 0360: lead-time pricing has its own card (the tiers as a table); 0361: the partner markup is no longer used
    const keys = Object.keys(s.program).filter((k) => !['id', 'effective_from', 'created_by', 'created_at', 'turnaround_block_minutes', 'owner_debit_show_legal_name', 'staff_agreement_defaults',
      'lead_time_enabled', 'lead_time_tiers', 'lead_time_insurer', 'partner_markup_bps', 'licence_auto_approver'].includes(k)
      // 0085's booking texts, replaced by Text alerts (0096: Settings > Text alerts)
      && !k.startsWith('phone_sms_'));
    const used = new Set<string>();
    return (<>{head}
      <p className="small muted">Saving writes a new dated row from today; the rows before it stay as they were. In force since {d(s.program.effective_from)}; {s.program_rows.length} dated rows.</p>
      <Card title="Lead-time pricing" testId="lead-time-card"><LeadTimeSettings enabled={s.program.lead_time_enabled !== false} insurer={s.program.lead_time_insurer === true}
        tiers={(s.program.lead_time_tiers ?? []) as Tier[]} /></Card>
      <Card title="Turnaround between trips" testId="turnaround-help"><p className="small">One time between trips, {String(s.program.turnaround_buffer_minutes)} minutes now (the owner&apos;s 2 hours by default). No trip may start sooner after another one ends, and a trip must end that long before the next one starts. After each trip the same time shows on the calendars as the cleaning block; it is not added on top. Removing a cleaning block frees that time for a new booking. A car can have its own turnaround under Vehicles, the car, Calendar. Change it under Booking requests and offers.</p></Card>
      {/* r35 S2 (1053): the marketing photo scenes and the photo of each one's real place */}
      <Card title="Marketing scenes" testId="marketing-scenes-card"><SceneReferences /></Card>
      <Card title="Photo import from Google Drive" testId="drive-key-card">
        <p className="small" data-testid="drive-key-state">{s.program.google_drive_api_key_set ? `A Google API key is set (ends ${String(s.program.google_drive_api_key_last4 ?? '')}). It is never shown in full.` : 'No key is set: the import reads the public folder page.'}</p>
        <SaveForm table="program_settings" rowKey="current" testId="program-drive-key" label="Save the key" fields={[{ name: 'google_drive_api_key', label: s.program.google_drive_api_key_set ? 'New key (replaces the one set; empty and Save removes it)' : 'Google API key (optional)', value: '', hint: 'A Google API key with the Drive API on. Set: the import lists and downloads through the Drive API and reads folders of any size.' }]} />
      </Card>
      {PROGRAM_GROUPS.map(([title, test]) => { const ks = keys.filter((k) => k !== 'google_drive_api_key' && !used.has(k) && test(k)); ks.forEach((k) => used.add(k)); if (!ks.length) return null; return (
        <Card key={title} title={title}><details open={title === 'Booking requests and offers'}><summary className="link">{ks.length} settings</summary>
          <SaveForm table="program_settings" rowKey="current" testId={`program-${title.split(' ')[0]!.toLowerCase()}`} fields={fieldsFrom(s.program, ks)} /></details></Card>); })}
      {/* r36 (2110): what the AI auto-replies did (their settings are the group above) */}
      <Card title="AI auto-replies: the last answers" testId="auto-replies-card"><AutoReplies /></Card>
      <Card title="Staff agreement defaults by function" testId="staff-defaults"><StaffDefaults value={(s.program.staff_agreement_defaults ?? {}) as StaffDefaultsValue} /></Card>
      <StuckReport d={await read<StuckReportData>('help_stuck').catch(() => null)} />
    </>);
  }
  case 'fees':
    return (<>{head}
      <Card title="Defaults in force"><Table rows={s.fee_defaults} cols={[{ key: 'fee_type_code', label: 'Fee', render: (r) => String((s.fee_types.find((f) => f.code === r.fee_type_code) ?? {}).label ?? r.fee_type_code) }, { key: 'vehicle_class', label: 'Class', render: (r) => r.vehicle_class ? String(r.vehicle_class) : 'all' },
        { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'percent_bps', label: '%', num: true, render: (r) => r.percent_bps !== null ? `${Number(r.percent_bps) / 100}%` : '' }, { key: 'cap_cents', label: 'Cap', num: true, render: (r) => $(r.cap_cents) },
        { key: 'min_cents', label: 'Min', num: true, render: (r) => $(r.min_cents) }, { key: 'max_cents', label: 'Max', num: true, render: (r) => $(r.max_cents) }, { key: 'effective_from', label: 'From', render: (r) => d(r.effective_from) }]} /></Card>
      <Card title="Set a new default"><SaveForm table="fee_defaults" label="Save the new default" fields={[{ name: 'fee_type_code', label: 'Fee', type: 'select', required: true, options: s.fee_types.map((f) => [String(f.code), String(f.label)]) }, { name: 'vehicle_class', label: 'Class (empty: all)', type: 'select', options: classOpts },
        { name: 'amount_cents', label: 'Amount', type: 'money' }, { name: 'percent_bps', label: 'Percentage', type: 'percent' }, { name: 'cap_cents', label: 'Cap', type: 'money' }, { name: 'min_cents', label: 'Minimum', type: 'money' }, { name: 'max_cents', label: 'Maximum', type: 'money' }, { name: 'grace_minutes', label: 'Grace minutes', type: 'number' }, { name: 'effective_from', label: 'Effective from', type: 'date', value: new Date().toISOString().slice(0, 10) }, { name: 'note', label: 'Note' }]} /></Card>
    </>);
  case 'deposits': case 'km': case 'classes': case 'airports': case 'insurers': case 'promo-codes': case 'quick-replies': {
    const cfg: Record<string, { table: string; key: string; rows: R[]; fields: (r: R) => Field[]; extra?: React.ReactNode }> = {
      deposits: { table: 'deposit_tiers', key: 'amount_cents', rows: s.deposit_tiers, fields: (r) => [{ name: 'amount_cents', label: 'Amount', type: 'money', required: true, value: r.amount_cents }, { name: 'label', label: 'Label', required: true, value: r.label }, { name: 'sort_order', label: 'Order', type: 'number', value: r.sort_order }, { name: 'is_active', label: 'Offered', type: 'bool', value: r.is_active ?? true }] },
      km: { table: 'km_allowance_choices', key: 'km_per_day', rows: s.km_choices, fields: (r) => [{ name: 'km_per_day', label: 'Kilometres a day', type: 'number', required: true, value: r.km_per_day }, { name: 'sort_order', label: 'Order', type: 'number', value: r.sort_order }, { name: 'is_active', label: 'Offered', type: 'bool', value: r.is_active ?? true }],
        extra: <Card title="Default for new rate cards" testId="km-default"><p className="small">A car&apos;s rate form starts with &quot;Use the defaults&quot;: this many kilometres included a day, then the extra kilometre rate of <Link prefetch={false} className="link" href="/admin/settings/fees">Fee defaults</Link> (Mileage overage, by class). Staff choose &quot;Custom for this car&quot; to change them for one car. The choices below are the usual custom values.</p>
          <SaveForm table="program_settings" rowKey="current" testId="km-default-form" fields={fieldsFrom(s.program, ['default_km_allowance_per_day'])} /></Card> },
      classes: { table: 'vehicle_classes', key: 'code', rows: s.classes, fields: (r) => [{ name: 'code', label: 'Code', required: true, value: r.code }, { name: 'label', label: 'Label', required: true, value: r.label }, { name: 'sort_order', label: 'Order', type: 'number', value: r.sort_order }, { name: 'is_active', label: 'Shown', type: 'bool', value: r.is_active ?? true }] },
      airports: { table: 'airports', key: 'id', rows: s.airports, fields: (r) => [{ name: 'code', label: 'Code', required: true, value: r.code }, { name: 'name', label: 'Name', required: true, value: r.name }, { name: 'latitude', label: 'Latitude', type: 'number', required: true, value: r.latitude }, { name: 'longitude', label: 'Longitude', type: 'number', required: true, value: r.longitude }, { name: 'distance_km', label: 'Distance (km)', type: 'number', value: r.distance_km }, { name: 'surcharge_cents', label: 'Surcharge', type: 'money', value: r.surcharge_cents }, { name: 'is_active', label: 'Offered', type: 'bool', value: r.is_active ?? true }],
        extra: <Card title="Delivery rate and origin"><SaveForm table="program_settings" rowKey="current" testId="delivery" fields={fieldsFrom(s.program, ['delivery_base_cents', 'delivery_included_km', 'delivery_per_km_cents', 'delivery_road_factor', 'delivery_min_cents', 'delivery_max_cents', 'delivery_round_cents', 'company_latitude', 'company_longitude', 'company_address'])} /></Card> },
      insurers: { table: 'insurers', key: 'id', rows: s.insurers, fields: (r) => [{ name: 'name', label: 'Name', required: true, value: r.name }, { name: 'billing_contact_name', label: 'Billing contact (optional: invoices go to each booking\'s adjuster)', value: r.billing_contact_name }, { name: 'billing_email', label: 'Billing email (optional: used when a booking has no adjuster email)', type: 'email', value: r.billing_email }, { name: 'billing_phone', label: 'Billing phone', type: 'tel', value: r.billing_phone }, { name: 'billing_address', label: 'Billing address', type: 'address', value: r.billing_address }, { name: 'notes', label: 'Notes', type: 'textarea', value: r.notes }, { name: 'is_active', label: 'Active', type: 'bool', value: r.is_active ?? true }] },
      'promo-codes': { table: 'promo_codes', key: 'id', rows: s.promo_codes, extra: <PromoExtra s={s} />, fields: (r) => [{ name: 'code', label: 'Code', required: true, value: r.code }, { name: 'description', label: 'Description', value: r.description }, { name: 'percent_bps', label: 'Percent off the rental', type: 'percent', value: r.percent_bps, info: 'discount_scope' }, { name: 'amount_cents', label: 'or amount off', type: 'money', value: r.amount_cents }, { name: 'valid_from', label: 'Valid from', type: 'datetime', value: r.valid_from }, { name: 'valid_until', label: 'Valid until', type: 'datetime', value: 'id' in r ? r.valid_until : promoEnd(s.program), hint: 'Starts 30 days ahead. Empty means no end date: only for a public code. A code for one person always has an end date.' }, { name: 'max_uses', label: 'Maximum uses', type: 'number', value: r.max_uses }, { name: 'once_per_renter', label: 'Once per renter', type: 'bool', value: r.once_per_renter ?? true }, { name: 'is_active', label: 'Active', type: 'bool', value: r.is_active ?? true }] },
      'quick-replies': { table: 'quick_replies', key: 'id', rows: s.quick_replies, fields: (r) => [{ name: 'title', label: 'Title', required: true, value: r.title }, { name: 'body', label: 'Text', type: 'textarea', required: true, value: r.body }, { name: 'category', label: 'Category', value: r.category }, { name: 'is_active', label: 'Active', type: 'bool', value: r.is_active ?? true }] }
    };
    const c = cfg[section]!;
    return (<>{head}
      {c.extra}
      <Card title={`${c.rows.length} on file`}>{c.rows.length ? c.rows.map((r) => (
        <details key={String(r[c.key])}><summary className="link">{String(r.label ?? r.name ?? r.code ?? r.title ?? (section === 'deposits' ? $(r.amount_cents) : `${String(r.km_per_day)} km`))}{r.is_active === false ? ' (off)' : ''}{r.uses !== undefined ? ` · ${String(r.uses)} uses` : ''}{r.reminders !== undefined ? ` · ${r.valid_until ? `ends ${d(r.valid_until)}` : 'no end date'}${r.personal ? ` · reminders: ${remindersText(r.reminders)}` : ''}` : ''}{r.unpaid_cents !== undefined ? ` · ${String(r.open_bookings)} open bookings, ${$(r.unpaid_cents)} unpaid` : ''}</summary>
          <SaveForm table={c.table} rowKey={String(r[c.key])} compact fields={c.fields(r)} /></details>)) : <p className="small muted">None yet.</p>}</Card>
      <Card title="Add"><SaveForm table={c.table} label="Add" testId={`add-${section}`} fields={c.fields({})} /></Card>
    </>);
  }
  case 'card-coverage': {
    const list = await read<CardList>('card_coverage');
    const fields = (r: R): Field[] => [
      { name: 'country', label: 'Issued in', type: 'select', required: true, options: [['CA', 'Canada'], ['US', 'United States']], value: r.country ?? 'CA' },
      { name: 'issuer', label: 'Issuer', required: true, value: r.issuer }, { name: 'card', label: 'Card', required: true, value: r.card },
      { name: 'coverage', label: 'Pays', type: 'select', required: true, options: (Object.keys(COVERAGE_LABEL) as CoverageKind[]).map((k) => [k, COVERAGE_LABEL[k]] as [string, string]), value: r.coverage ?? 'ask' },
      { name: 'max_msrp_cents', label: 'Car value limit (MSRP)', type: 'money', value: r.max_msrp_cents, hint: 'Empty when the guide gives no MSRP limit: say what it does say below.' },
      { name: 'value_note', label: 'Value limit in the guide\'s words', value: r.value_note, wide: true },
      { name: 'max_days', label: 'Longest rental (days)', type: 'number', min: 1, max: 366, value: r.max_days },
      // 1400: the facts the booking check uses (the renter picks the card; the database checks the car against them)
      { name: 'network', label: 'Network', type: 'select', required: true, options: Object.entries(NETWORK_LABEL), value: r.network ?? 'unknown' },
      { name: 'cdw_included', label: 'Includes rental car damage coverage (CDW)', type: 'select', required: true, options: Object.entries(YES_NO_LABEL), value: r.cdw_included ?? 'unknown', hint: 'Unknown sends every renter with this card to staff review.' },
      { name: 'excluded_types', label: 'Vehicle types not covered', value: Array.isArray(r.excluded_types) ? (r.excluded_types as string[]).join(', ') : '', wide: true,
        hint: `Comma separated, from: ${Object.keys(VEHICLE_TYPE_LABEL).join(', ')}. A car of one of them is refused for this card.` },
      { name: 'must_decline_cdw', label: 'Must decline the rental company\'s CDW', type: 'select', required: true, options: Object.entries(YES_NO_LABEL), value: r.must_decline_cdw ?? 'unknown' },
      { name: 'must_pay_full', label: 'Must pay the full rental on the card', type: 'select', required: true, options: Object.entries(YES_NO_LABEL), value: r.must_pay_full ?? 'unknown' },
      { name: 'exclusions', label: 'Key exclusions', type: 'textarea', value: r.exclusions ?? '', wide: true },
      { name: 'conditions', label: 'To use it (decline the waiver, pay with the card)', type: 'textarea', value: r.conditions ?? '', wide: true },
      { name: 'car_sharing', label: 'Car sharing and peer-to-peer', value: r.car_sharing, wide: true },
      { name: 'note', label: 'Note shown with the card', type: 'textarea', value: r.note, wide: true },
      { name: 'guide_url', label: 'Official guide (https://)', value: r.guide_url, wide: true },
      { name: 'source_url', label: 'Where the numbers came from, if not the issuer (https://)', value: r.source_url, wide: true },
      { name: 'issuer_checked', label: 'Read in the issuer\'s own document', type: 'bool', value: r.issuer_checked ?? false },
      { name: 'last_checked', label: 'Last checked', type: 'date', value: r.last_checked, hint: 'Changing the facts without a date marks the card checked today.' },
      { name: 'sort_order', label: 'Order', type: 'number', value: r.sort_order ?? 0 }, { name: 'is_active', label: 'Shown', type: 'bool', value: r.is_active ?? true }];
    const rows = list.cards as unknown as R[];
    return (<>{head}
      <p className="small muted">The list on <Link prefetch={false} className="link" href="/credit-card-rental-coverage">/credit-card-rental-coverage</Link> and in the staff quick reference. Facts only: open the issuer&apos;s guide, correct the card and save it. A card not checked for 6 months shows on Today.</p>
      <Card title={`${rows.length} cards`} testId="card-coverage-admin"><Table rows={rows} cols={[{ key: 'card', label: 'Card', render: (r) => `${String(r.issuer)} ${String(r.card)}${r.country === 'US' ? ' (US)' : ''}${r.is_active === false ? ' (hidden)' : ''}` },
        { key: 'coverage', label: 'Pays', render: (r) => COVERAGE_LABEL[r.coverage as CoverageKind] }, { key: 'cdw_included', label: 'CDW', render: (r) => YES_NO_LABEL[String(r.cdw_included ?? 'unknown')] ?? '' },
        { key: 'max_msrp_cents', label: 'MSRP limit', num: true, render: (r) => $(r.max_msrp_cents) },
        { key: 'excluded_types', label: 'Not covered', render: (r) => (Array.isArray(r.excluded_types) ? (r.excluded_types as string[]).map((x) => VEHICLE_TYPE_LABEL[x] ?? x).join(', ') : '') },
        { key: 'max_days', label: 'Days', num: true }, { key: 'issuer_checked', label: 'Issuer\'s document', render: (r) => yes(r.issuer_checked) }, { key: 'last_checked', label: 'Checked', render: (r) => d(r.last_checked) }]} /></Card>
      <Card title="Change a card">{rows.map((r) => <details key={String(r.id)}><summary className="link" data-testid={`card-edit-${String(r.issuer)}-${String(r.card)}`.toLowerCase().replace(/[^a-z0-9]+/g, '-')}>{String(r.issuer)} {String(r.card)}{r.country === 'US' ? ' (US)' : ''}</summary>
        <SaveForm table="card_rental_coverage" rowKey={String(r.id)} compact fields={fields(r)} /></details>)}</Card>
      <Card title="Add a card"><SaveForm table="card_rental_coverage" label="Add" testId="add-card-coverage" fields={fields({})} /></Card>
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
      <p className="small"><Link prefetch={false} className="link" href="/admin/logs?tab=emails">Email log and blocked addresses</Link></p>
    </>);
  case 'staff': {
    // 1060: the preferred name, the last use and the inactivity lock
    const access = await door<Record<string, { last_active_at: string | null; locked_at: string | null; lock_reason?: string | null; preferred_name: string | null; location?: string | null; townhalls_missed?: number }>>(user.id, 'admin_read', 'staff_access_facts', {}).catch(() => ({} as Record<string, { last_active_at: string | null; locked_at: string | null; lock_reason?: string | null; preferred_name: string | null; location?: string | null; townhalls_missed?: number }>));
    return (<>{head}
      <Card title="Invite"><p className="small muted">An invitation email with a link to choose a password (24 hours), then their portal. Owners and investors on file are invited from <Link prefetch={false} className="link" href="/admin/portals#invite">Admin &gt; Portals</Link>. Admin access is only through the addresses under Admin access below.</p><InviteForm roles={['staff']} testId="staff-invite" /></Card>
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
      <Card title="Staff"><Table rows={s.staff} testId="staff" cols={[{ key: 'full_name', label: 'Name', render: (r) => <>{String(r.full_name ?? '')}{access[String(r.id)]?.preferred_name ? <span className="small muted"> ({access[String(r.id)]!.preferred_name})</span> : null}{access[String(r.id)]?.locked_at ? <> <span className="ad-flag ad-flag--red" data-testid={`locked-${String(r.email)}`}>{access[String(r.id)]!.lock_reason === 'townhall' ? 'Locked: two townhalls missed' : 'Locked for inactivity'}</span></> : null}
          {access[String(r.id)]?.location ? <span className="cr-sub small muted">{access[String(r.id)]!.location}</span> : null}
          {(access[String(r.id)]?.townhalls_missed ?? 0) > 0 ? <> <span className="ad-flag" data-testid={`th-missed-${String(r.email)}`}>Missed {access[String(r.id)]!.townhalls_missed} townhall{access[String(r.id)]!.townhalls_missed === 1 ? '' : 's'} (8 weeks)</span></> : null}</> }, { key: 'email', label: 'Email' }, { key: 'roles', label: 'Roles', render: (r) => (r.roles as string[] | null)?.join(', ') },
        { key: 'fn', label: 'Functions', render: (r) => { const p = r.profile as R | null; if (!p) return ''; return staffFns(p).map((f) => `${STAFF_FN_LABEL[f]}${f === 'sales' && p.sales_work_mode ? ` (${p.sales_work_mode === 'remote' ? 'remote' : 'in person'})` : ''}${f === 'field' && p.field_function ? ` (${label(p.field_function)})` : ''}`).join(', '); } }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'last_sign_in_at', label: 'Last sign-in', render: (r) => t(r.last_sign_in_at ?? access[String(r.id)]?.last_active_at ?? null) },
        { key: 'limits', label: 'Limits', render: (r) => { const p = r.profile as R | null; return p ? `${$(p.single_limit_cents)} / ${$(p.dual_approval_threshold_cents)}` : ''; } },
        { key: 'academy', label: 'Academy', render: (r) => { const a = academy?.get(String(r.id)); return a && a.sections ? <Link prefetch={false} className="link" href={`/admin/academy/staff/${String(r.id)}`} data-testid={`academy-${String(r.email)}`}>{a.done ? 'Passed' : `${a.passed} of ${a.sections}`}</Link> : ''; } },
        { key: 'act', label: 'Actions', render: (r) => r.id === user.id ? <span className="muted small">you</span> : <span className="ad-actions">
          {access[String(r.id)]?.locked_at && <Act action="staff_unlock" payload={{ user_id: r.id }} label="Unlock" variant="primary" testId={`unlock-${String(r.email)}`} refresh={['/admin/settings/staff']} done="Unlocked: they can sign in again." />}
          {r.status === 'active' && <PasswordLinkButton userId={String(r.id)} testId={`pw-${String(r.email)}`} />}
          {r.status === 'active' && (r.profile as R | null) && staffFns(r.profile as R).filter((f) => f !== 'field')
            .map((f) => <ViewAsButton key={f} user={String(r.id)} portal="va" fn={f} label={`View as (${STAFF_FN_LABEL[f]})`} testId={`view-as-${String(r.email)}-${f}`} />)}
          {r.status === 'active' && (r.profile as R | null) && staffFns(r.profile as R).includes('field') && <ViewAsButton user={String(r.id)} portal="field" label={`View as (${STAFF_FN_LABEL.field})`} testId={`view-as-${String(r.email)}-field`} />}
          {(r.profile as R | null) && <StaffFunctions user={String(r.id)} functions={staffFns(r.profile as R)} salesMode={((r.profile as R).sales_work_mode as string | null) ?? null} fieldRole={((r.profile as R).field_function as string | null) ?? null} testId={`functions-${String(r.email)}`} />}
          {(r.profile as R | null) && <SaveFormLimits id={String(r.id)} p={r.profile as R} />}
          {(r.profile as R | null)?.va_function ? <>
            <Link prefetch={false} className="link small" href={`/admin/staff/${String(r.id)}/scorecard`}>Scorecard</Link>
            <Link prefetch={false} className="link small" href={`/admin/staff/${String(r.id)}/sales`} data-testid={`sales-${String(r.email)}`}>Sales</Link>
</> : null}
          {r.status === 'active' ? <Act action="staff_end" payload={{ user: r.id }} label="End access" variant="danger" confirm={`End ${String(r.full_name)}'s access now? The staff portal closes to them at once.`} refresh={['/admin/settings/staff']} />
            : <Act action="staff_restore" payload={{ user: r.id }} label="Restore" refresh={['/admin/settings/staff']} />}</span> }]} /></Card>
      {await (async () => {
        const sm = await read<SalesModes>('sales_modes').catch(() => null);
        return sm ? <SalesModesCard data={sm} /> : null;
      })()}
      <Card title="Staff onboarding" testId="staff-onboarding-card">
        {/* 1154: step 4, Approve or Reject (with the reason) */}
        <OnboardingApprovals admin refresh={['/admin/settings/staff']} rows={await door<ApprovalRow[]>(user.id, 'ops_read', 'staff_onboarding_approvals', {}).catch(() => [])} />
        <StaffOnboarding rows={await door<OnboardingRow[]>(user.id, 'ops_read', 'staff_onboarding_list', {}).catch(() => [])} /></Card>
      <Card title="Staff agreements" testId="staff-agreements"><AgreementGate rows={await door<AgreementGateRow[]>(user.id, 'ops_read', 'staff_agreements_status', {}).catch(() => [])} />
        <StaffAgreements rows={await door<StaffAgreementRow[]>(user.id, 'ops_read', 'staff_agreements', {}).catch(() => [])} today={new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date())} /></Card>
    </>);
  }
  }
  notFound();
}

function SaveFormLimits({ id, p }: { id: string; p: R }) {
  return <details><summary className="link small">Limits</summary><SaveForm table="staff_profiles" rowKey={id} compact fields={[{ name: 'single_limit_cents', label: 'Single limit', type: 'money', value: p.single_limit_cents }, { name: 'dual_approval_threshold_cents', label: 'Second approval above', type: 'money', value: p.dual_approval_threshold_cents }]} /></details>;
}

// R23 (0220): one IndexNow sender's last answer in words: status, Bing's message, and how long it waits
type IxAnswer = { status: number | null; error: string | null; at: string | null; until: string | null };
function ixLine(a: IxAnswer | undefined, t: (x: string) => string): string {
  if (!a || !a.at) return 'Nothing sent yet';
  const msg = a.error ? (/"message":"([^"]+)"/.exec(a.error)?.[1] ?? a.error).slice(0, 120) : '';
  return `last answer ${a.status ?? 'none'} ${t(a.at)}${msg ? ` (${msg})` : ''}${a.until ? `; waits until ${t(a.until)}` : ''}`;
}
