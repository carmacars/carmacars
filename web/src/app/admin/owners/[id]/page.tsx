import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { money, pct } from '@/lib/format';
import { Back, Dl } from '@/features/portal/Blocks';
import { day, monthOf } from '@/features/owner/Blocks';
import { invoiceStatus, invoiceTitle, METHOD_LABEL, MODE_LABEL, ONBOARDING_STATUS, PAY_METHOD_LABEL } from '@/features/owner/types';
import { IssueInvoices, PendingTerms, SendLinkForm, TermsForm, TrackerActions } from '@/features/admin/AdminForms';
import { InviteRecordButton, PasswordLinkButton } from '@/features/admin/AccountTools';
import { ViewAsButton } from '@/features/admin/ViewAs';
import { adminOwner, requireAdmin } from '@/server/admin/data';
import { adminRead } from '@/server/admin/api';
import { $, Badge, Card, Table, t as at } from '@/features/admin/ui';
import Link from 'next/link';
import { Cosigners, type CosignerRow } from '@/features/admin/LegalActions';
import { door } from '@/server/door';
import { ManualPaymentForm, ManualPaymentList, PaperSignatureList, type ManualRow, type PaperRow } from '@/features/manual/ManualRecords';
import { OwnerChecklist, type OwnerChecklistRow } from '@/features/manual/OwnerChecklist';
import { Tabs } from '@/features/admin/ui';
import { InvoiceList, type InvoiceListData } from '@/features/owner-billing/InvoiceList';
import { TermsPanel, type TermsData } from '@/features/owner-billing/TermsPanel';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner', path: '/admin/owners', noindex: true, description: 'An owner application.' });

const TERMS_OPEN = ['intake', 'terms_set'];
const ISSUABLE = ['terms_set', 'documents_sent', 'documents_signed'];
const yes = (v: unknown) => (v ? 'Yes' : 'No');

// One owner (04-owner.md section 4, the parts needed for billing today): what the owner entered, the
// terms per vehicle (the standard grid by default), the upfront invoices, payments and links.
export default async function AdminOwner({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, { id }, sp] = await Promise.all([requireAdmin('/admin/owners'), params, searchParams]);
  const d = await adminOwner(user, id);
  if (!d) notFound();
  // the tabs of 0067: Overview (as before), Terms (negotiated per owner and car), Invoices (every invoice, drafts included)
  const tab = sp.tab === 'terms' || sp.tab === 'invoices' ? sp.tab : 'overview';
  const tabs: Array<[string, string, number?]> = [[`/admin/owners/${id}`, 'Overview'], [`/admin/owners/${id}?tab=terms`, 'Terms'], [`/admin/owners/${id}?tab=invoices`, 'Invoices', d.invoices.length]];
  const head = (
    <>
      <Back href="/admin/owners">Owner applications</Back>
      <header className="stack"><p className="pt-kicker">{d.applications.map((a) => a.application_number).join(', ')} · {d.owner.owner_type === 'corporation' ? 'Corporation' : 'Individual'}</p><h1 className="d2">{d.owner.legal_name}</h1>
        <p className="muted">{[d.owner.email, d.owner.phone].filter(Boolean).join(' · ')}</p>
        <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}><Link prefetch={false} className="btn btn--ghost btn--sm" href={`/admin/owners/add-car?owner=${id}`} data-testid="owner-add-car">Add another car</Link>
          <Link prefetch={false} className="btn btn--ghost btn--sm" href={`/admin/invoices/new?owner=${id}`} data-testid="owner-new-invoice">New invoice</Link></div></header>
      <Tabs items={tabs} current={tab === 'overview' ? `/admin/owners/${id}` : `/admin/owners/${id}?tab=${tab}`} label="Owner" />
    </>
  );
  const todayIso = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  if (tab === 'terms') {
    const terms = await door<TermsData>(user.id, 'ops_read', 'owner_terms', { owner_id: id });
    return <>{head}<TermsPanel data={terms} ownerId={id} today={todayIso} /></>;
  }
  if (tab === 'invoices') {
    const list = await door<InvoiceListData>(user.id, 'ops_read', 'owner_invoices_admin', { owner_id: id });
    return <>{head}<InvoiceList data={list} owner={false} newHref={`/admin/invoices/new?owner=${id}`} testId="owner-invoice-list" /></>;
  }
  const [rec, witnessed] = await Promise.all([
    adminRead<{ documents: Array<Record<string, unknown>>; statements: Array<Record<string, unknown>>; payouts: Array<Record<string, unknown>>; deductions: Array<Record<string, unknown>> }>(user.id, 'owner_records', { id }),
    // Forms C and D signed with witnesses (migration 0040)
    adminRead<Array<{ code: string; vehicle_name: string | null; title: string; status: string; reject_reason: string | null; uploaded_at: string | null }>>(user.id, 'owner_witnessed_forms', { owner: id }).catch(() => [])]);
  // what is paid and signed, the paper signatures and the payments recorded by hand (migration 0044)
  const cosigners = await door<CosignerRow[]>(user.id, 'ops_read', 'owner_cosigners', { owner_id: id }).catch(() => [] as CosignerRow[]);
  const [checklist, paper, manual] = await Promise.all([
    door<OwnerChecklistRow[]>(user.id, 'ops_read', 'owner_checklists', { owner: id }).then((r) => r[0] ?? null).catch(() => null),
    door<PaperRow[]>(user.id, 'ops_read', 'paper_signatures', { owner: id }).catch(() => [] as PaperRow[]),
    Promise.all(d.invoices.filter((i) => (i.manual ?? []).length > 0).map(async (i) => [i.id, await door<ManualRow[]>(user.id, 'ops_read', 'manual_payments', { invoice: i.id }).catch(() => [] as ManualRow[])] as const)).then((x) => new Map(x))]);
  const here = [`/admin/owners/${id}`];
  const o = d.owner;
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  const issuable = d.vehicles.filter((v) => !v.upfront_invoice && ISSUABLE.includes(v.onboarding.status) && v.schedule && ['managed', 'self_managed'].includes(v.billing_case)).length;
  return (
    <>
      {head}
      <div className="pt-split">
        <div className="stack-lg">
          {d.vehicles.map((v) => (
            <section key={v.vehicle_id} className="pt-card" aria-label={v.name} data-testid="admin-vehicle">
              <div className="pt-card__head"><h2 className="d4">{v.name}</h2><span className="badge badge--outline">{ONBOARDING_STATUS[v.onboarding.status] ?? v.onboarding.status}</span></div>
              <Dl rows={[['VIN, plate', `${v.vin}, ${v.plate ?? 'none'}`], ['Colour, odometer', `${v.colour ?? ''}, ${v.odometer_km?.toLocaleString('en-CA') ?? '?'} km`],
                ['Held by, status', `${v.onboarding.held_by ?? ''}, ${(v.onboarding.title_status ?? '').replace(/_/g, ' ')}${v.onboarding.finance_party_name ? ` (${v.onboarding.finance_party_name}, permission ${v.onboarding.finance_permission?.replace(/_/g, ' ')})` : ''}`],
                ['Asked for', `${MODE_LABEL[v.onboarding.proposed_management_mode ?? ''] ?? ''}, ${METHOD_LABEL[v.onboarding.proposed_onboarding_method ?? ''] ?? 'method not chosen'}${v.onboarding.situation ? ` (${v.onboarding.situation})` : ''}`],
                ['Registry estimate (owner pays)', v.onboarding.estimate_cents !== null ? `${money(v.onboarding.estimate_cents)}${v.onboarding.estimate_plus_tax ? ' plus any tax' : ''}` : ''],
                ['Current insurer', v.onboarding.current_insurer ?? ''],
                ['Damage or recall disclosed', v.onboarding.disclosures ? `${yes((v.onboarding.disclosures as Record<string, unknown>).damage)}${(v.onboarding.disclosures as Record<string, unknown>).details ? `: ${String((v.onboarding.disclosures as Record<string, unknown>).details)}` : ''}` : 'No'],
                ['Declined', v.onboarding.decline_reason ?? '']]} />
              {v.onboarding.pending_terms && (
                <div className="ow-warn"><b>Terms waiting for your approval</b>
                  <span>{money(v.onboarding.pending_terms.insurance_fee_cents)} insurance, {money(v.onboarding.pending_terms.tracker_fee_cents)} tracker, {pct(v.onboarding.pending_terms.revenue_share_bps)} share, {money(v.onboarding.pending_terms.install_fee_cents)} install, {MODE_LABEL[v.onboarding.pending_terms.management_mode]}</span>
                  <PendingTerms ownerId={o.id} vehicleId={v.vehicle_id} /></div>
              )}
              {v.schedule && <p className="small"><b>Terms set</b> ({v.schedule.schedule_number}{v.schedule.signed_at ? `, signed ${day(v.schedule.signed_at)}` : ', not signed yet'}): {money(v.schedule.insurance_fee_cents)} insurance, {money(v.schedule.tracker_fee_cents)} tracker, {pct(v.schedule.revenue_share_bps)} Revenue Share, {money(v.schedule.install_fee_cents)} install, {MODE_LABEL[v.schedule.management_mode]}, {METHOD_LABEL[v.schedule.onboarding_method]}.</p>}
              {TERMS_OPEN.includes(v.onboarding.status) && !v.is_shareholder_owned && (
                <details open={!v.schedule}><summary className="link">{v.schedule ? 'Change the terms' : 'Set the terms'}</summary>
                  <TermsForm ownerId={o.id} vehicleId={v.vehicle_id} standard={v.standard} mode={v.schedule?.management_mode ?? v.onboarding.proposed_management_mode ?? 'managed'}
                    method={v.schedule?.onboarding_method ?? v.onboarding.proposed_onboarding_method} options={v.options} current={v.schedule} /></details>
              )}
              {v.billing_case !== 'turo_only' && v.billing_case !== 'shareholder' && (
                <div className="small stack" data-testid="admin-tracker">
                  <p><b>Tracker:</b> {v.tracker_installed_on ? `installed ${day(v.tracker_installed_on)}` : v.tracker_install_pending ? 'install pending (no tracker fees billed)' : 'not recorded'}{v.tracker_invoice ? `. Install invoice ${v.tracker_invoice.invoice_number}: ${money(v.tracker_invoice.total_cents, { cents: true })}, ${invoiceStatus({ status: v.tracker_invoice.status, pending: false }).label.toLowerCase()}.` : '. No install invoice yet.'}</p>
                  {v.schedule && (!v.tracker_invoice || v.tracker_install_pending) && <TrackerActions ownerId={o.id} vehicleId={v.vehicle_id} installed={v.tracker_install_pending} canIssue={!v.tracker_invoice} />}
                </div>
              )}
              {v.upfront_invoice && <p className="small">Upfront invoice <a href={`#inv-${v.upfront_invoice.invoice_number}`}>{v.upfront_invoice.invoice_number}</a>: {money(v.upfront_invoice.total_cents, { cents: true })}, {invoiceStatus({ status: v.upfront_invoice.status, pending: false }).label.toLowerCase()}.</p>}
            </section>
          ))}
          {checklist && (
            <section className="pt-card stack" id="checklist" aria-labelledby="ad-ck"><h2 className="d4" id="ad-ck">Paid and signed</h2>
              <p className="small">Everything this owner signs and pays to get their cars on the road, and how each was done. A payment received by e-Transfer, cheque, cash or bank transfer, or a document signed on paper, is recorded here and counts everywhere.</p>
              <OwnerChecklist row={checklist} signer={o.owner_type === 'corporation' ? String(o.signing_officer_name ?? o.legal_name) : o.legal_name} today={today} refresh={here} />
              <h3 className="d5">Paper signatures</h3>
              <PaperSignatureList rows={paper} canVoid refresh={here} />
            </section>
          )}
          <section className="stack" aria-labelledby="ad-inv"><h2 className="pt-section-title" id="ad-inv">Invoices</h2>
            {d.invoices.length ? <ul className="ow-rows" data-testid="admin-owner-invoices">{d.invoices.map((i) => { const s = invoiceStatus(i); const paid = i.payments.find((x) => x.status === 'succeeded'); return (
              <li key={i.id} id={`inv-${i.invoice_number}`} data-invoice={i.invoice_number}>
                <span><b><Link prefetch={false} className="link" href={`/admin/invoices/${i.invoice_number}`}>{i.invoice_number}</Link></b> · {invoiceTitle(i, monthOf)} · {i.vehicle_name}</span>
                <span className="ow-amount">{money(i.total_cents, { cents: true })}</span>
                <span className="ow-meta"><span className={`badge ${s.badge}`} data-testid="admin-invoice-status">{i.partly_paid ? 'Partly paid' : s.label}</span>{i.paid_by ? <span>{i.paid_by.replace(/^Paid /, '')}</span> : paid && <span>{PAY_METHOD_LABEL[paid.method] ?? paid.method}{paid.reference ? ` ${paid.reference}` : paid.card_last4 ? ` ending ${paid.card_last4}` : ''}, {day(paid.processed_at ?? paid.created_at)}</span>}
                  {i.partly_paid && <span>{money(i.balance_cents, { cents: true })} owing</span>}</span>
                {manual.get(i.id) && <div style={{ flex: '1 1 100%' }}><ManualPaymentList rows={manual.get(i.id)!} canVoid refresh={here} /></div>}
                {i.payable && <div style={{ flex: '1 1 100%' }}><ManualPaymentForm invoice={i.id} number={i.invoice_number} balance={i.balance_cents} today={today} refresh={here} /></div>}
              </li>); })}</ul> : <p className="pt-empty muted">No invoices yet.</p>}
          </section>
        </div>
        <aside className="pt-split__aside stack-lg">
          <section className="pt-card" aria-labelledby="ad-up"><h2 className="d4" id="ad-up">Upfront invoices</h2>
            <p className="small">The first and last month amount agreed on each car&apos;s terms, with HST, one invoice per vehicle whose terms are set. For other amounts or to choose what is sent, use the Invoices tab. The Tracker Install Fee is a separate invoice, issued per vehicle when trackers arrive{d.trackers_available ? '' : ' (trackers are not available yet)'}. Registry costs are never billed.</p>
            <IssueInvoices ownerId={o.id} count={issuable} />
          </section>
          <section className="pt-card" aria-labelledby="ad-owner"><h2 className="d4" id="ad-owner">Owner</h2>
            <Dl rows={[['Address', [o.address_line1, o.city, o.province, o.postal_code].filter(Boolean).join(', ')], ['Corporation', o.corporation_name ? `${String(o.corporation_name)}, no. ${String(o.corporation_number ?? '')}` : ''], ['HST number', String(o.hst_number ?? '')], ['Licence', o.private?.licence_number ? `${o.private.licence_number} (${o.private.licence_province ?? 'ON'})` : ''], ['Date of birth', o.private?.date_of_birth ?? ''], ['Sign-in', o.user_email ?? 'No account'], ['Agreements', `Enrollment ${d.signing.enrollment ?? 'not prepared'}, title ${d.signing.title_holding ?? 'not prepared'}`], ['Still missing', o.missing.join(', ')]]} />
          </section>
          <Card title="Owners in the Title Schedule" testId="owner-cosigners-card">
            <Cosigners ownerId={id} ownerName={o.legal_name} rows={cosigners} locked={d.signing.enrollment === 'signed'} /></Card>
          <Card title="Statements and payouts"><Table rows={rec.statements} empty="No statements." cols={[{ key: 'statement_month', label: 'Month', render: (r) => <Link prefetch={false} className="link" href={`/admin/statements/${String(r.id)}`}>{monthOf(String(r.statement_month))}</Link> }, { key: 'status', label: 'Status' }, { key: 'payout_cents', label: 'Payout', num: true, render: (r) => $(r.payout_cents) }]} />
            <Table rows={rec.payouts} empty="No payouts." cols={[{ key: 'kind', label: 'Payout' }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'status', label: 'Status' }]} /></Card>
          <Card title="Forms C and D" aside={<Link prefetch={false} className="link small" href="/admin/owner-forms">Review queue</Link>}>
            <Table rows={witnessed} testId="owner-witnessed" empty="No witnessed form is needed yet." cols={[{ key: 'title', label: 'Form', render: (r) => <>{String(r.title)}{r.vehicle_name ? <><br /><span className="small">{String(r.vehicle_name)}</span></> : null}</> }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'reject_reason', label: 'Note', className: 'wrap' }, { key: 'uploaded_at', label: 'Uploaded', render: (r) => at(r.uploaded_at) }]} /></Card>
          <Card title="Documents"><Table rows={rec.documents} empty="No documents." cols={[{ key: 'title', label: 'Document' }, { key: 'kind', label: 'Kind' }, { key: 'created_at', label: 'Added', render: (r) => at(r.created_at) }]} /></Card>
          <section className="pt-card stack" aria-labelledby="ad-signin"><h2 className="d4" id="ad-signin">Owner portal sign-in</h2>
            {o.user_id ? <><p className="small">Signs in as <b>{o.user_email ?? o.email}</b>.</p>
              <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}><ViewAsButton user={String(o.user_id)} portal="owner" testId="view-as-owner" /><PasswordLinkButton userId={String(o.user_id)} /></div></>
              : <><p className="small muted">No sign-in yet.</p><InviteRecordButton role="owner" recordId={o.id} email={o.email} name={o.legal_name} testId="invite-owner" /></>}</section>
          <section className="pt-card" aria-labelledby="ad-link"><h2 className="d4" id="ad-link">Send the owner a link</h2><SendLinkForm kind="portal" email={o.email ?? ''} name={o.legal_name} /></section>
        </aside>
      </div>
    </>
  );
}
