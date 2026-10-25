import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { Act } from '@/features/admin/Act';
import { $, Badge, BookingLink, Card, Kv, PageHead, Table, t, d } from '@/features/admin/ui';
import { InviteRecordButton, PasswordLinkButton } from '@/features/admin/AccountTools';
import { ViewAsButton } from '@/features/admin/ViewAs';
import { PaperSignatureForm } from '@/features/manual/ManualRecords';
import { PARTNER_FIELDS } from '@/features/supply/partner-fields';
import { PartnerPayoutForm } from '@/features/supply/PartnerPayoutForm';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Partner', path: '/admin/partners', noindex: true, description: 'One partner rental company.' });

type R = Record<string, unknown>;
type P = R & { id: string; owner_id: string; partner_number: string; business_name: string; legal_name: string | null; contact_name: string | null; email: string | null; phone: string | null;
  status: string; commission_bps: number | null; commission_effective_bps: number; insurance_company: string | null; insurance_policy: string | null; insurance_expiry: string | null;
  insurance_warning: string | null; agreement_status: string; agreement_method: string | null; agreement_signed_at: string | null; agreement_document_id: string | null;
  has_portal: boolean; portal_user_id: string | null; cars: R[]; bookings: R[]; statements: R[]; payouts: R[]; payout_accounts: R[]; documents: R[];
  paper: { id: string; signed_on: string; signer_name: string } | null;
  /** 0093: the markup on the sheet rates, the basis, the chauffeur vehicles */
  markup_bps: number | null; markup_effective_bps: number; payout_basis: 'renter_price' | 'partner_rate'; chauffeur: R[] };

// One partner (migration 0046): the record, its cars and their commission, bookings, statements and payouts, the payout
// account (Admins only), the partner agreement (portal or paper) and the portal sign-in.
export default async function Partner({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { user } = await page(`/admin/partners/${id}`);
  const p = await door<P | null>(user.id, 'ops_read', 'partner', { id });
  if (!p) notFound();
  const refresh = [`/admin/partners/${id}`, '/admin/partners'];
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Toronto' });
  return (
    <>
      <PageHead kicker={<><Link prefetch={false} className="link" href="/admin/partners">Partners</Link> · {p.partner_number}</>} title={<>{p.business_name} <Badge s={p.status} /></>}>
        <Act ops action="partner_save" payload={{ id }} label="Edit" testId="partner-edit" refresh={refresh} fields={PARTNER_FIELDS(p)} />
        <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/vehicles/new">Add a car</Link>
        <Link prefetch={false} className="btn btn--ghost btn--sm" href={`/admin/settings/partners/${id}`} data-testid="partner-crm-link">CRM link</Link>
      </PageHead>
      <div className="ad-cols ad-cols--2">
        <Card title="Partner" testId="partner-facts">
          <Kv rows={[['Contact', `${p.contact_name ?? ''}${p.email ? `, ${p.email}` : ''}${p.phone ? `, ${p.phone}` : ''}`], ['Legal name', p.legal_name ?? p.business_name],
            ['Commission', `${p.commission_effective_bps / 100}%${p.commission_bps == null ? ' (the default in Program settings)' : ''}`],
            ['Their insurance', `${p.insurance_company ?? 'Not on file'}${p.insurance_policy ? `, policy ${p.insurance_policy}` : ''}${p.insurance_expiry ? `, expires ${d(p.insurance_expiry)}` : ''}`],
            ['Agreement', <span key="a" data-testid="partner-agreement-status">{p.agreement_status === 'signed' ? `Signed ${p.agreement_method === 'paper' ? 'on paper' : 'in the portal'}${p.agreement_signed_at ? ` on ${d(p.agreement_signed_at)}` : ''}` : p.agreement_status === 'sent' ? 'Opened in the portal, not signed yet' : 'Not signed yet'}</span>]]} />
          {p.insurance_warning && <p className="alert alert--warn" role="note"><span>{p.insurance_warning}. Ask the partner for their current insurance.</span></p>}
        </Card>
        <Card title="Portal and agreement">
          <p className="small muted">The partner uses the owner portal: their cars, bookings, statements and payouts, and the partner agreement to sign on screen. Or sign it on paper and record it here.</p>
          <div className="ad-actions">
            {p.portal_user_id ? <><ViewAsButton user={p.portal_user_id} portal="owner" testId="partner-view-as" /><PasswordLinkButton userId={p.portal_user_id} /></>
              : <InviteRecordButton role="owner" recordId={p.owner_id} email={p.email} name={p.business_name} testId="partner-invite" />}
          </div>
          {p.agreement_status !== 'signed' && <p className="small"><a className="link" href={`/admin/partners/${id}/agreement`} target="_blank" rel="noopener" data-testid="partner-agreement-print">Print the partner agreement</a> to sign on paper.</p>}
          {p.agreement_status !== 'signed' && <PaperSignatureForm docs={[{ doc_type: 'partner_agreement', target_id: id, label: 'Partner agreement', signer: p.contact_name ?? p.business_name }]} today={today} refresh={refresh} testId="partner-paper" />}
          {p.agreement_document_id && <p className="small"><Link prefetch={false} className="link" href={`/admin/documents/${p.agreement_document_id}`}>Open the signed agreement</Link></p>}
        </Card>
        <Card title="Pricing" testId="partner-pricing" aside={<Act ops action="partner_pricing_save" payload={{ id }} label="Edit pricing" testId="partner-pricing-edit" refresh={refresh} fields={[
            { name: 'markup_bps', label: 'Markup on their sheet rates (empty: Program settings)', type: 'percent', value: p.markup_bps },
            { name: 'commission_bps', label: 'CarmaCars cut of their sheet rate (empty: Program settings)', type: 'percent', value: p.commission_bps },
            { name: 'payout_basis', label: 'Paid on', type: 'select', value: p.payout_basis, options: [['partner_rate', 'Their sheet rate (the markup stays with CarmaCars)'], ['renter_price', 'What the renter paid']] }]} />}>
          <Kv rows={[['Renter pays', `Their sheet rate plus ${p.markup_effective_bps / 100}%, to the nearest dollar${p.markup_bps == null ? ' (Program settings)' : ''}`],
            ['CarmaCars keeps', p.payout_basis === 'partner_rate' ? `The markup, plus ${p.commission_effective_bps / 100}% of the sheet rate` : `${p.commission_effective_bps / 100}% of what the renter paid`],
            ['Partner is owed', p.payout_basis === 'partner_rate' ? `${100 - p.commission_effective_bps / 100}% of their sheet rate, on the monthly statement` : `${100 - p.commission_effective_bps / 100}% of what the renter paid`]]} />
          <p className="small muted">Each car keeps its own sheet rates (1 to 2 days, 3 or more, 7 or more, a day) and may have its own markup or cut: Edit on its row. The renter rates follow at once. Replace the stand-in photos with real ones on the car page (Photos).</p>
        </Card>
        <Card title={`Cars (${p.cars.length})`} testId="partner-cars">
          <Table rows={p.cars} empty="No cars yet." cols={[{ key: 'name', label: 'Car', render: (r) => <><Link prefetch={false} className="link" href={`/admin/vehicles/${String(r.id)}`}>{String(r.name)}</Link>{r.year_approximate ? <span className="small muted"> · year {String(r.year)}, not confirmed</span> : null}{r.insurance_included ? <span className="small"> · insurance included</span> : null}{r.no_credit_card ? <span className="small"> · no credit card</span> : null}{!r.real_photos && r.base_cents != null ? <span className="small muted"> · stand-in photos</span> : null}</> },
            { key: 'base_cents', label: 'Sheet a day (1-2, 3+, 7+)', num: true, render: (r) => (r.base_cents == null ? 'None' : `${$(r.base_cents)}, ${$(r.multi_day_cents)}, ${$(r.long_term_cents)}`) },
            { key: 'renter_daily_cents', label: 'Renter a day (1-2, 3+, 7+)', num: true, render: (r) => (r.renter_daily_cents == null ? 'None' : `${$(r.renter_daily_cents)}, ${r.renter_multi_day_cents != null ? $(r.renter_multi_day_cents) : 'none'}, ${r.renter_long_term_cents != null ? $(r.renter_long_term_cents) : 'none'}`) },
            { key: 'commission_effective_bps', label: 'Cut, markup', num: true, render: (r) => `${Number(r.commission_effective_bps) / 100}%${r.commission_bps == null ? '' : ' (own)'}, ${Number(r.markup_effective_bps) / 100}%${r.markup_bps == null ? '' : ' (own)'}` },
            { key: 'listing_status', label: 'Listing', render: (r) => (r.retired_at ? 'Retired' : String(r.listing_status ?? '')) },
            { key: 'id', label: '', render: (r) => <Act ops action="partner_car_save" payload={{ vehicle_id: r.id }} label="Edit" testId={`partner-car-edit-${String(r.sheet_name ?? r.id).toLowerCase().replace(/[^a-z0-9]+/g, '-')}`} refresh={refresh} fields={[
              { name: 'base_cents', label: 'Their rate a day, 1 to 2 days', type: 'money', value: r.base_cents, required: true },
              { name: 'multi_day_cents', label: 'Their rate a day, 3 days or more', type: 'money', value: r.multi_day_cents, required: true },
              { name: 'long_term_cents', label: 'Their rate a day, 7 days or more', type: 'money', value: r.long_term_cents, required: true },
              { name: 'markup_bps', label: 'This car\'s markup (empty: the partner\'s)', type: 'percent', value: r.markup_bps },
              { name: 'commission_bps', label: 'This car\'s cut (empty: the partner\'s)', type: 'percent', value: r.commission_bps },
              { name: 'insurance_included', label: 'Insurance included: no personal auto policy needed', type: 'bool', value: r.insurance_included },
              { name: 'no_credit_card', label: 'No credit card needed: debit accepted', type: 'bool', value: r.no_credit_card },
              { name: 'year', label: 'Model year', type: 'number', min: 1980, max: 2100, value: r.year },
              { name: 'year_approximate', label: 'Year not confirmed yet (the site says "Year confirmed when you book")', type: 'bool', value: r.year_approximate }]} /> }]} />
        </Card>
        {p.chauffeur.length > 0 && <Card title={`Chauffeur vehicles (${p.chauffeur.length})`} testId="partner-chauffeur" aside={<Link prefetch={false} className="link small" href="/admin/chauffeur">Requests</Link>}>
          <Table rows={p.chauffeur} cols={[{ key: 'name', label: 'Vehicle', render: (r) => <>{String(r.name)}<br /><span className="small muted">{r.kind === 'chauffeur_only' ? 'Chauffeur only' : `Also a rental: ${((r.rentals as Array<{ name: string }>) ?? []).map((x) => x.name).join(', ') || 'none on file'}`}{r.active ? '' : ' · off the site'}</span></> },
            { key: 'sheet_2h_cents', label: 'Sheet an hour (2, 3+)', num: true, render: (r) => `${$(r.sheet_2h_cents)}, ${$(r.sheet_3plus_cents)}` },
            { key: 'rate_2h_cents', label: 'Client an hour (2, 3+)', num: true, render: (r) => `${$(r.rate_2h_cents)}, ${$(r.rate_3plus_cents)}` },
            { key: 'id', label: '', render: (r) => <Act ops action="chauffeur_vehicle_save" payload={{ id: r.id }} label="Edit" refresh={refresh} fields={[
              { name: 'sheet_2h_cents', label: 'Their rate an hour, 2 hours', type: 'money', value: r.sheet_2h_cents, required: true },
              { name: 'sheet_3plus_cents', label: 'Their rate an hour, 3 hours or more', type: 'money', value: r.sheet_3plus_cents, required: true },
              { name: 'markup_bps', label: 'Markup (empty: the partner\'s)', type: 'percent', value: r.markup_bps },
              { name: 'cut_bps', label: 'Cut (empty: the partner\'s)', type: 'percent', value: r.cut_bps },
              { name: 'passengers', label: 'Passengers', type: 'number', min: 1, max: 20, value: r.passengers },
              { name: 'active', label: 'On the site', type: 'bool', value: r.active }]} /> }]} />
        </Card>}
        <Card title="Payout account (Admins only)" testId="partner-payout">
          <Table rows={p.payout_accounts} empty="No payout account yet." cols={[{ key: 'method', label: 'Method', render: (r) => (r.method === 'e_transfer' ? `e-Transfer ${String(r.e_transfer_email ?? '')}` : `Bank ${String(r.institution_no ?? '')}-${String(r.transit_no ?? '')} ending ${String(r.account_last4 ?? '')}`) },
            { key: 'account_holder', label: 'Holder' }, { key: 'verified_at', label: 'Verified', render: (r) => (r.verified_at ? t(r.verified_at) : <Act ops action="partner_payout_verify" payload={{ account_id: r.id }} label="Verify" refresh={refresh} fields={[{ name: 'method', label: 'How it was verified (a call to the number on file)', type: 'text', required: true }]} />) },
            { key: 'is_current', label: 'In use', render: (r) => (r.is_current ? 'Yes' : 'No') }]} />
          <PartnerPayoutForm partnerId={id} holder={p.legal_name ?? p.business_name} />
        </Card>
        <Card title="Bookings"><Table rows={p.bookings} empty="No bookings yet." cols={[{ key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> },
          { key: 'vehicle', label: 'Car' }, { key: 'pickup_at', label: 'Pickup', render: (r) => t(r.pickup_at) }, { key: 'total_cents', label: 'Total', num: true, render: (r) => $(r.total_cents) }]} /></Card>
        <Card title="Statements and payouts">
          <Table rows={p.statements} empty="No statements yet. Partner statements are built with the owner statements each month." cols={[{ key: 'statement_number', label: 'Statement', render: (r) => <Link prefetch={false} className="link" href={`/admin/statements/${String(r.id)}`}>{String(r.statement_number ?? 'Draft')}</Link> },
            { key: 'statement_month', label: 'Month', render: (r) => d(r.statement_month) }, { key: 'status', label: 'Status' }, { key: 'payout_cents', label: 'Payout', num: true, render: (r) => $(r.payout_cents) }]} />
          <Table rows={p.payouts} empty="No payouts yet." cols={[{ key: 'created_at', label: 'Created', render: (r) => t(r.created_at) }, { key: 'status', label: 'Status' }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }]} />
        </Card>
        <Card title="Documents"><Table rows={p.documents} empty="No documents." cols={[{ key: 'title', label: 'Title', render: (r) => <Link prefetch={false} className="link" href={`/admin/documents/${String(r.id)}`}>{String(r.title ?? r.kind)}</Link> }, { key: 'created_at', label: 'Added', render: (r) => t(r.created_at) }]} /></Card>
      </div>
    </>
  );
}
