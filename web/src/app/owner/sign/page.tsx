import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { money, pct } from '@/lib/format';
import { rpc } from '@/lib/db/repo';
import { Back } from '@/features/portal/Blocks';
import { AgreementView } from '@/features/agreement/AgreementView';
import { CONFIRMATIONS, type OwnerAgreementFacts } from '@/features/owner-agreement/model';
import { screenFormBlocks, SCREEN_FORM_TITLE } from '@/features/owner-agreement/screen-forms';
import { partnerAgreementBlocks, PARTNER_AGREEMENT_TITLE, type PartnerFacts } from '@/features/partner/agreement';
import type { Official } from '@/features/official-forms/OfficialForm';
import { OwnerPackage } from '@/features/signing/OwnerPackage';
import { SignProgress, SignSummary, type ProgressItem, type SummaryRow } from '@/features/signing/Progress';
import { ownerForms, requireOwner } from '@/server/owner/data';
import { openOwnerPacket } from '@/server/owner/agreements';
import { formABFacts, openFormAB, openPartnerAgreement, partnerFacts } from '@/server/sign-requests';
import { signOwnerPackage, type OwnerPackageSpec } from '@/server/actions/signing';
import { viewAs } from '@/server/view-as';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign your documents', path: '/owner/sign', noindex: true, description: 'Everything you sign with CarmaCars, filled from your records, signed once.' });

const SR = { role: 'service_role' as const };
type Checklist = { items: Array<{ code: string; label: string; status: 'done' | 'open'; vehicle_id?: string | null; vehicle_name?: string | null; detail?: string | null; how: string }>; done: number; total: number };
type ScreenForm = { code: 'A' | 'B'; title: string; status: 'needed' | 'signed' };
const MODE: Record<string, string> = { managed: 'Managed', self_managed: 'Self-Managed', turo_only: 'Turo-Only' };

// Signing, simply (migration 0049): every document the owner still signs, filled from what they already gave us, in one
// package. A short list of the key values with a Fix link for each, the full text one tap away, the statements the
// agreement asks to initial (one tap, initials filled in), the signature (their legal name, or drawn), one button. Forms
// C and D are signed on paper in front of witnesses (the forms ask for witnesses, and a power of attorney cannot be
// signed electronically in Ontario): they show in the checklist with their own page.
export default async function OwnerSign() {
  const { user, home } = await requireOwner('/owner/sign');
  const viewing = !!(await viewAs());
  const partner = home.kind === 'partner';
  const checklist = (await rpc('server_my_signing_checklist', { p_by: user.id }, SR).catch(() => null)) as unknown as Checklist | null;

  // what this package holds
  const packet = partner ? { facts: null as OwnerAgreementFacts | null, docs: [] as Awaited<ReturnType<typeof openOwnerPacket>>['docs'] } : await openOwnerPacket(home.owner.id, user.id);
  const screen = partner ? [] : ((await rpc('owner_screen_forms', { p_by: user.id }, SR).catch(() => [])) as unknown as ScreenForm[]).filter((f) => f.status !== 'signed');
  const forms: Array<{ code: 'A' | 'B'; id: string; sha: string; title: string; blocks: ReturnType<typeof screenFormBlocks> }> = [];
  for (const f of screen) {
    const facts = await formABFacts(user.id, f.code);
    const open = viewing ? { id: '', sha: '' } : await openFormAB(user.id, f.code);
    forms.push({ code: f.code, id: open.id, sha: open.sha, title: SCREEN_FORM_TITLE[f.code], blocks: screenFormBlocks(facts) });
  }
  let pa: { id: string; sha: string; facts: PartnerFacts } | null = null;
  if (partner && home.partner?.agreement_status !== 'signed') {
    const facts = await partnerFacts(user.id);
    if (facts) pa = viewing ? { id: '', sha: '', facts } : await openPartnerAgreement(user.id);
  }
  const officials: Official[] = [];
  if (!partner) {
    for (const f of (await ownerForms(user)).filter((x) => x.official && x.status === 'ready')) {
      const o = (await rpc('owner_form_official', { p_by: user.id, p_fill: f.id }, SR).catch(() => null)) as unknown as Official | null;
      if (o && Object.values(o.field_map).some((s) => typeof s !== 'string' && s.type === 'signature')) officials.push(o);
    }
  }

  const docs = [
    ...packet.docs.map((d) => ({ key: d.key, title: d.title })),
    ...forms.map((f) => ({ key: `form-${f.code}`, title: f.title })),
    ...(pa ? [{ key: 'partner', title: PARTNER_AGREEMENT_TITLE }] : []),
    ...officials.map((o) => ({ key: `official-${o.id}`, title: `${o.form_code} (${o.vehicle_name})` }))
  ];
  const spec: OwnerPackageSpec = {
    packet: packet.docs.map((d) => ({ key: d.key, sha: d.sha, title: d.title })),
    requests: [...forms.map((f) => ({ id: f.id, sha: f.sha, title: f.title })), ...(pa ? [{ id: pa.id, sha: pa.sha, title: PARTNER_AGREEMENT_TITLE }] : [])]
  };

  // the checklist: what is in this package is marked; the rest says where it is done
  const inPackage = (code: string) => (code === 'enrollment' || code === 'title_holding' || code === 'schedule') ? packet.docs.length > 0
    : code === 'form_a' || code === 'form_b' ? forms.some((f) => `form_${f.code.toLowerCase()}` === code) : code === 'partner_agreement' ? !!pa : code === 'registry_form' ? officials.length > 0 : false;
  const items: ProgressItem[] = (checklist?.items ?? []).map((i, n) => ({
    key: `${i.code}-${i.vehicle_id ?? ''}-${n}`, label: `${i.label}${i.vehicle_name && i.code !== 'registry_form' ? `, ${i.vehicle_name}` : ''}`, done: i.status === 'done',
    note: i.status === 'done' ? null : i.how === 'paper' ? 'print it filled in, sign it with your witness, then take a photo of the signed page' : i.how === 'banking' ? 'set up in Banking' : i.detail ?? null,
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
              {officials.map((o) => <details key={o.id}><summary>{o.form_code}: {o.title ?? 'registry form'} ({o.vehicle_name})</summary>
                <p className="small">The official ServiceOntario form, filled from your records. Your signature goes in its signature box. <Link prefetch={false} className="link" href={`/owner/documents/forms/${o.id}/official`}>Download it to check</Link>.</p></details>)}
            </section>
          </div>
          <aside className="pt-split__aside">
            <section className="pt-card" aria-labelledby="ow-sign"><h2 className="d4" id="ow-sign">Sign</h2>
              {viewing ? <p className="small muted">Read only.</p> : (
                <OwnerPackage docs={docs} signerName={signer} officials={officials} initials={enrollment}
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
