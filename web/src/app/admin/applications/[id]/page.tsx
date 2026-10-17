import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { Badge, Card, Kv, PageHead, d, t } from '@/features/admin/ui';
import { ApplicationChecks, ApplicationDecision, ApplicationNotes } from '@/features/admin/ApplicationActions';
import { APP_STATUS } from '@/features/admin/applications';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Application', path: '/admin/applications', noindex: true, description: 'One owner application.' });

type R = Record<string, unknown>;
interface View {
  application: { id: string; application_number: string; status: string; created_at: string; checks: Record<string, { status: string; note: string | null; at: string }>;
    requested_items: string[]; request_message: string | null; requested_at: string | null; owner_reply: string | null; owner_replied_at: string | null; decline_reason: string | null; decided_at: string | null };
  owner: R & { id: string; legal_name: string; owner_type: string; email: string | null; phone: string | null; address: string; licence_number: string | null; licence_province: string | null;
    date_of_birth: string | null; has_account: boolean; corporation_name: string | null; is_test: boolean; other_applications: string[] };
  vehicles: Array<R & { id: string; name: string; vin: string; plate: string | null; colour: string | null; odometer_km: number | null; management_mode: string; onboarding_status: string;
    title_status: string | null; finance_party_name: string | null; current_insurer: string | null; proposed_onboarding_method: string | null; estimate_cents: number | null;
    decode: { ok: boolean; year: string | null; make: string | null; model: string | null; trim: string | null; body_class: string | null; fuel: string | null; drivetrain: string | null; error_code: string | null } | null }>;
  documents: Array<{ id: string; kind: string; title: string; vehicle: string | null; created_at: string }>;
  notes: Array<{ id: string; kind: string; body: string; at: string; by: string | null }>;
  invoices: Array<{ invoice_number: string; kind: string; status: string; total_cents: number }>;
  items: Array<{ code: string; label: string }>;
}

// One owner application on one page (October 16, 2026): the owner, the car with its VIN decode, the documents, the four
// checks, the notes; then Approve, Ask for something or Decline.
export default async function Application({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { user } = await page(`/admin/applications/${id}`);
  const v = await door<View>(user.id, 'ops_read', 'application', { id }).catch(() => null);
  if (!v) notFound();
  const a = v.application; const o = v.owner;
  const label = (s: string | null | undefined) => (s ? s.replace(/_/g, ' ') : '');
  return (
    <>
      <PageHead kicker={<Link prefetch={false} className="link" href="/admin/applications">Applications</Link>} title={`${a.application_number}: ${o.legal_name}`}>
        <Badge s={a.status === 'new' ? 'requested' : a.status === 'waiting_on_owner' ? 'sent' : a.status}>{APP_STATUS[a.status]}</Badge>
      </PageHead>
      {a.status === 'waiting_on_owner' && <p className="alert alert--warn" role="status"><span>Asked on {t(a.requested_at)} for: {v.items.filter((i) => a.requested_items.includes(i.code)).map((i) => i.label).join('; ')}.{a.request_message ? ` "${a.request_message}"` : ''} Waiting on the owner.</span></p>}
      {a.owner_reply && a.status === 'new' && <p className="alert alert--ok" role="status"><span className="alert__title">The owner answered on {t(a.owner_replied_at)}</span><span>{a.owner_reply}</span></p>}
      {a.status === 'declined' && <p className="alert alert--error" role="status"><span>Declined on {d(a.decided_at)}: {a.decline_reason}</span></p>}
      <div className="ad-cols ad-cols--main">
        <div className="stack">
          <Card title="Owner" testId="app-owner">
            <Kv rows={[['Name', o.legal_name], ['Type', o.owner_type === 'corporation' ? `Corporation${o.corporation_name ? `: ${o.corporation_name}` : ''}` : 'Individual'], ['Email', o.email], ['Phone', o.phone],
              ['Address', o.address], ['Licence', o.licence_number ? `${o.licence_number} (${o.licence_province ?? 'ON'})` : 'Not given'], ['Date of birth', o.date_of_birth ? d(o.date_of_birth) : 'Not given'],
              ['Sign-in', o.has_account ? 'Has an account' : 'No account yet'], ['Other applications', o.other_applications.join(', ')], ['Applied', t(a.created_at)]]} />
            <p className="small"><Link prefetch={false} className="link" href={`/admin/owners/${o.id}`}>Open the owner record</Link></p>
          </Card>
          {v.vehicles.map((x) => (
            <Card key={x.id} title={x.name} testId="app-vehicle" aside={<Badge s={x.onboarding_status} />}>
              <Kv rows={[['VIN', <span key="v" className="pt-mono">{x.vin}</span>], ['VIN decode', x.decode ? (x.decode.ok ? [x.decode.year, x.decode.make, x.decode.model, x.decode.trim, x.decode.body_class, x.decode.fuel, x.decode.drivetrain].filter(Boolean).join(' · ') : `Could not decode (${x.decode.error_code ?? 'no answer'})`) : 'Not decoded yet'],
                ['Plate', x.plate], ['Colour', x.colour], ['Odometer', x.odometer_km ? `${x.odometer_km.toLocaleString('en-CA')} km` : ''], ['Held as', label(x.title_status)], ['Lender', x.finance_party_name],
                ['Insurer now', x.current_insurer], ['How it will work', label(x.management_mode)], ['Onboarding method', label(x.proposed_onboarding_method)], ['Registry estimate', x.estimate_cents ? money(x.estimate_cents, { cents: true }) : '']]} />
              <p className="small"><Link prefetch={false} className="link" href={`/admin/vehicles/${x.id}`}>Open the car</Link></p>
            </Card>))}
          <Card title={`Documents uploaded (${v.documents.length})`} testId="app-documents">
            {v.documents.length ? <ul className="ad-list">{v.documents.map((x) => <li key={x.id}><span><Link prefetch={false} className="link" href={`/admin/documents/${x.id}`}>{x.title || label(x.kind)}</Link>{x.vehicle ? <span className="muted"> · {x.vehicle}</span> : null}</span><span className="small">{d(x.created_at)}</span></li>)}</ul>
              : <p className="small muted">Nothing uploaded yet. Use Ask for something to request the ownership permit, the insurance slip or the lender&apos;s permission.</p>}
          </Card>
          {v.invoices.length > 0 && <Card title="Invoices"><ul className="ad-list">{v.invoices.map((i) => <li key={i.invoice_number}><span>{i.invoice_number} · {label(i.kind)}</span><span>{money(i.total_cents, { cents: true })} · {label(i.status)}</span></li>)}</ul></Card>}
        </div>
        <div className="stack">
          <Card title="Decide" testId="app-decide"><ApplicationDecision id={a.id} status={a.status} items={v.items} owner={o.legal_name} isTest={o.is_test} /></Card>
          <Card title="Checks" testId="app-checks"><ApplicationChecks id={a.id} checks={a.checks} disabled={a.status === 'approved' || a.status === 'declined'} /></Card>
          <Card title="Notes" testId="app-notes"><ApplicationNotes id={a.id} notes={v.notes} /></Card>
        </div>
      </div>
    </>
  );
}
