import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { money, pct } from '@/lib/format';
import { rpc } from '@/lib/db/repo';
import { Back } from '@/features/portal/Blocks';
import { AgreementView } from '@/features/agreement/AgreementView';
import { CONFIRMATIONS, type PacketKey } from '@/features/owner-agreement/model';
import { partnerAgreementBlocks, PARTNER_AGREEMENT_TITLE } from '@/features/partner/agreement';
import { OwnerPackage } from '@/features/signing/OwnerPackage';
import type { EsignDoc } from '@/features/signing/types';
import { SignProgress, SignSummary, type ProgressItem, type SummaryRow } from '@/features/signing/Progress';
import { requireOwner } from '@/server/owner/data';
import { findOpen, formABFacts, formSpec, ownerAgreementFacts, packetSpecs, partnerFacts, partnerSpec } from '@/server/signing/prepare';
import { PrepareDocs } from '@/features/signing/PrepareDocs';
import { SignTrouble } from './SignTrouble';
import { signOwnerPackage, type OwnerPackageSpec } from '@/server/actions/signing';
import { viewAs } from '@/server/view-as';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign your documents', path: '/owner/sign', noindex: true, description: 'Everything you sign with CarmaCars, filled from your records, signed once.' });

const SR = { role: 'service_role' as const };
type Checklist = { items: Array<{ code: string; label: string; status: 'done' | 'open'; vehicle_id?: string | null; vehicle_name?: string | null; detail?: string | null; how: string }>; done: number; total: number };
type ScreenForm = { code: 'A' | 'B'; title: string; status: 'needed' | 'signed' };
const MODE: Record<string, string> = { managed: 'Managed', self_managed: 'Self-Managed', turo_only: 'Turo-Only' };

// Signing, simply (migration 0049): every document the owner still signs, filled from what they already gave us, in one
// package. A short list of the key values with a Fix link for each, the full text one tap away, then the signing steps of
// every signature (0181: a code to the phone or email, the reading, the confirmations initialled, the consents, the drawn
// signature), one button. Forms
// C and D are signed on paper in front of witnesses (the forms ask for witnesses, and a power of attorney cannot be
// signed electronically in Ontario): they show in the checklist with their own page.
export default async function OwnerSign() {
  const { user, home } = await requireOwner('/owner/sign');
  try {
    return await SignPage({ user, home });
  } catch (e) {
    // a redirect or another of Next's own signals goes on; anything else is shown as a friendly message (and logged)
    if (e && typeof e === 'object' && 'digest' in e && /^NEXT_|^DYNAMIC_SERVER_USAGE/.test(String((e as { digest: unknown }).digest))) throw e;
    console.error('owner sign page', e);
    return <SignTrouble />;
  }
}

async function SignPage({ user, home }: Awaited<ReturnType<typeof requireOwner>>) {
  const viewing = !!(await viewAs());
  const partner = home.kind === 'partner';
  // what this package holds, read in parallel; no PDF is made here (migration 0077)
  const [checklist, facts, screen, pFacts] = await Promise.all([
    rpc('server_my_signing_checklist', { p_by: user.id }, SR).catch(() => null) as unknown as Promise<Checklist | null>,
    partner ? Promise.resolve(null) : ownerAgreementFacts(home.owner.id, user.id),
    partner ? Promise.resolve([] as ScreenForm[]) : (rpc('owner_screen_forms', { p_by: user.id }, SR).catch(() => []) as unknown as Promise<ScreenForm[]>).then((x) => x.filter((f) => f.status !== 'signed')),
    partner && home.partner?.agreement_status !== 'signed' ? partnerFacts(user.id) : Promise.resolve(null)
  ]);
  const packetSpecsList = facts ? await packetSpecs(facts, home.owner.id, user.id) : [];
  const formSpecs = await Promise.all(screen.map(async (f) => formSpec(user.id, f.code, await formABFacts(user.id, f.code))));
  const paSpec = pFacts ? await partnerSpec(user.id, pFacts) : null;
  const all = [...packetSpecsList, ...formSpecs, ...(paSpec ? [paSpec] : [])];
  const open = await findOpen(user.id, all);
  const missing = all.filter((d) => !open.has(d.key));

  const packet = { facts, docs: packetSpecsList.map((d) => ({ key: (d.target as { key: PacketKey }).key, title: d.title, blocks: d.blocks, sha: open.get(d.key)?.sha ?? '' })) };
  const forms = formSpecs.map((d) => ({ code: (d.target as { code: 'A' | 'B' }).code, id: open.get(d.key)?.id ?? '', sha: open.get(d.key)?.sha ?? '', title: d.title, blocks: d.blocks }));
  const pa = paSpec && pFacts ? { id: open.get(paSpec.key)?.id ?? '', sha: open.get(paSpec.key)?.sha ?? '', facts: pFacts } : null;

  const docs = [
    ...packet.docs.map((d) => ({ key: d.key, title: d.title })),
    ...forms.map((f) => ({ key: `form-${f.code}`, title: f.title })),
    ...(pa ? [{ key: 'partner', title: PARTNER_AGREEMENT_TITLE }] : [])
  ];
  // what the signing session covers: each document with the SHA-256 shown (the database checks each, 0181)
  const esignDocs: EsignDoc[] = [
    ...packet.docs.map((d) => ({ kind: 'packet' as const, ref: d.key, sha: d.sha, title: d.title })),
    ...forms.map((x) => ({ kind: 'request' as const, ref: x.id, sha: x.sha, title: x.title })),
    ...(pa ? [{ kind: 'request' as const, ref: pa.id, sha: pa.sha, title: PARTNER_AGREEMENT_TITLE }] : [])
  ];
  const spec: OwnerPackageSpec = {
    packet: packet.docs.map((d) => ({ key: d.key, sha: d.sha, title: d.title })),
    requests: [...forms.map((f) => ({ id: f.id, sha: f.sha, title: f.title })), ...(pa ? [{ id: pa.id, sha: pa.sha, title: PARTNER_AGREEMENT_TITLE }] : [])]
  };

  // the checklist: what is in this package is marked; the rest says where it is done
  const inPackage = (code: string) => (code === 'enrollment' || code === 'title_holding' || code === 'schedule') ? packet.docs.length > 0
    : code === 'form_a' || code === 'form_b' ? forms.some((f) => `form_${f.code.toLowerCase()}` === code) : code === 'partner_agreement' ? !!pa : false;
  const items: ProgressItem[] = (checklist?.items ?? []).map((i, n) => ({
    key: `${i.code}-${i.vehicle_id ?? ''}-${n}`, label: `${i.label}${i.vehicle_name && i.code !== 'registry_form' ? `, ${i.vehicle_name}` : ''}`, done: i.status === 'done',
    note: i.status === 'done' ? null : i.how === 'paper' ? 'print it filled in, sign it with your witness, then take a photo of the signed page' : i.how === 'banking' ? 'set up in Banking'
      : i.how === 'registry' ? i.detail ?? 'print it filled in and sign it in ink' : i.detail ?? null,
    href: i.how === 'paper' ? '/owner/documents#ow-wit' : i.how === 'banking' ? '/owner/banking' : i.how === 'registry' ? '/owner/documents' : null,
    here: i.status !== 'done' && inPackage(i.code)
  }));

  // the key values, each with where to fix it
  const rows: SummaryRow[] = [];
  const f = packet.facts;
  if (f) {
    rows.push({ label: 'Signing as', value: f.owner.owner_type === 'corporation' ? `${f.owner.signer_name}, for ${f.owner.corporation_name ?? f.owner.legal_name}` : f.owner.signer_name, fix: '/owner/profile' });
    rows.push({ label: 'Address', value: f.owner.address ?? '', fix: '/owner/profile' });
    rows.push({ label: 'Email and phone', value: [f.owner.email, f.owner.phone].filter(Boolean).join(', '), fix: '/owner/profile' });
    for (const s of f.schedules.filter((x) => !x.signed_at)) {
      rows.push({ label: `${s.year} ${s.make} ${s.model}`, value: `VIN ${s.vin}, plate ${s.plate ?? 'not registered yet'}. ${MODE[s.management_mode] ?? s.management_mode}: Insurance Fee ${money(s.insurance_fee_cents)} and Tracker Fee ${money(s.tracker_fee_cents)} a month, Revenue Share ${pct(s.revenue_share_bps)}.`, fix: `/owner/vehicles/${s.vehicle_id}` });
    }
    if (f.owner.payout) rows.push({ label: 'Payouts to', value: f.owner.payout, fix: '/owner/banking' });
  } else if (pa) {
    rows.push({ label: 'Signing as', value: `${pa.facts.partner.signer_name}${pa.facts.partner.signer_title ? `, ${pa.facts.partner.signer_title}` : ''}, for ${pa.facts.partner.legal_name || pa.facts.partner.business_name}`, fix: '/owner/profile' });
    rows.push({ label: 'Address', value: pa.facts.partner.address, fix: '/owner/profile' });
    rows.push({ label: 'Commission', value: `${pct(pa.facts.commission_bps)} of rental revenue to CarmaCars`, fix: null });
    rows.push({ label: 'Your insurance', value: [pa.facts.insurance.company, pa.facts.insurance.policy, pa.facts.insurance.expiry ? `expires ${pa.facts.insurance.expiry}` : null].filter(Boolean).join(', '), fix: null });
    rows.push({ label: 'Cars', value: pa.facts.cars.map((c) => `${c.name}${c.plate ? ` (${c.plate})` : ''}`).join('; ') || 'None yet', fix: null });
  }

  const signer = f?.owner.signer_name ?? pa?.facts.partner.signer_name ?? home.owner.legal_name;
  const enrollment = packet.docs.some((d) => d.key === 'enrollment');
  return (
    <>
      <Back href="/owner">Owner portal</Back>
      <header className="stack">
        <p className="pt-kicker">{docs.length ? `${docs.length} to sign, one signature` : 'Signing'}</p>
        <h1 className="d2">{docs.length ? 'Sign your documents' : 'Nothing to sign here'}</h1>
        {docs.length > 0 && <p className="muted">Everything is filled in from what you already gave us. Check the values below, fix anything that is wrong, then sign once for all of them. It takes about a minute.</p>}
      </header>
      <SignProgress items={items} />
      {f?.waiting_for_owners && (
        <section className="ow-status" data-testid="owner-waiting-cosigners"><h2 className="d3">Signed by you</h2>
          <p>Every Owner named in the Title Schedule signs. The agreements take effect when the last one signs; CarmaCars countersigns then.</p>
          <ul>{(f.cosigners ?? []).map((c) => <li key={c.id}>{c.name}: {c.status === 'signed' ? 'signed' : 'waiting for their signature (we emailed them their own link)'}</li>)}</ul></section>
      )}
      {!docs.length ? (
        <div className="pt-empty"><p className="muted">{home.vehicles.some((v) => v.onboarding_status === 'intake') ? 'We are preparing the terms for your vehicles. We email you when your documents are ready.' : 'Your signed documents are in Documents.'}</p>
          <Link prefetch={false} className="btn btn--primary" href="/owner/documents">Documents</Link></div>
      ) : (
        <div className="pt-split">
          <div className="stack-lg">
            <SignSummary rows={rows} />
            <section className="stack sg-docs" aria-labelledby="sg-docs-h">
              <h2 className="d4" id="sg-docs-h">The documents ({docs.length})</h2>
              <p className="small muted">The full text of each, word for word. Open any of them to read it.</p>
              {packet.docs.map((d) => <details key={d.key}><summary>{d.title}</summary><AgreementView blocks={d.blocks} id={`ow-doc-${d.key}`} label={d.title} /></details>)}
              {forms.map((x) => <details key={x.code}><summary>{x.title}</summary><AgreementView blocks={x.blocks} id={`form-${x.code.toLowerCase()}`} label={x.title} /></details>)}
              {pa && <details><summary>{PARTNER_AGREEMENT_TITLE}</summary><AgreementView blocks={partnerAgreementBlocks(pa.facts)} id="partner-agreement" label={PARTNER_AGREEMENT_TITLE} /></details>}
            </section>
          </div>
          <aside className="pt-split__aside">
            <section className="pt-card" aria-labelledby="ow-sign"><h2 className="d4" id="ow-sign">Sign</h2>
              {viewing ? <p className="small muted">Read only.</p> : missing.length ? (
                <PrepareDocs targets={missing.map((d) => d.target)} titles={missing.map((d) => d.title)} />
              ) : (
                <OwnerPackage docs={docs} signerName={signer} role={partner ? 'partner' : 'owner'} esignDocs={esignDocs}
                  statements={enrollment ? CONFIRMATIONS.map((c) => ({ code: c.code, text: c.text })) : []}
                  consent={`By pressing Sign you sign ${docs.length > 1 ? `these ${docs.length} documents` : 'this document'} electronically, with the same effect as signing on paper. We record the time, your IP address and device. ${(f?.cosigners ?? []).some((c) => c.status !== 'signed') ? `Every Owner named in the Title Schedule signs with their own link (${(f?.cosigners ?? []).map((c) => c.name).join(', ')}); CarmaCars countersigns when the last one signs.` : 'CarmaCars countersigns at the same moment.'}`}
                  button={docs.length > 1 ? `Sign all ${docs.length}` : 'Sign'} action={signOwnerPackage.bind(null, spec)} />
              )}
            </section>
          </aside>
        </div>
      )}
    </>
  );
}
