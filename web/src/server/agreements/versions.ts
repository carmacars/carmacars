import 'server-only';
import { rpc, DbError } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { storage } from '@/integrations/storage';
import { sha256Hex } from '@/server/links';
import { AGREEMENT_TEMPLATE_VERSION, when, type SignatureRow } from '@/features/agreement/model';
import type { Change, VersionHeader } from '@/features/agreement/extra';
import { appendCertificate, appendSignaturePage, type CertSigner } from '@/features/signing/certificate';
import { fillBlindSpot, type Signature } from '@/features/blindspot/fill';
import { initialsOf, loadBundle, renderBlindSpot, renderCarmaCars, verifyUrl } from '@/server/agreements/bundle';

// The versions of a booking's two agreements (migration 0154). The database decides (app.agreement_plan): nothing
// changed, the open agreement to render again (unsigned), or a new version: the "as picked up" copy, the closing copy,
// a correction filed without signing, or a material change the renter (and the drivers it affects) sign again. The
// site renders both documents and records them (public.server_agreement_version_add, refused when the booking changed
// in between: the job runs again). A version signed by everyone gets its signed copies (the signatures page and the
// certificate of completion added to the documents they signed, byte for byte).
const SR = { role: 'service_role' as const };

interface Plan {
  state: 'none' | 'unsigned' | 'wait' | 'current' | 'version'; renter_user_id?: string; acting_user_id?: string; any_signed?: boolean; agreement_number?: string; original_signed_at?: string | null;
  kind?: VersionHeader['kind']; material?: boolean; changes?: Change[]; snapshot_sha?: string; next_no?: number; previous_no?: number;
  signers?: Array<{ role: string; name: string }>; amendment_number?: string | null;
  pickup?: { staff_name: string | null; at: string } | null; return?: { staff_name: string | null; at: string } | null;
}

/** One booking's agreements brought up to date. Returns what was done. */
export async function runVersionJob(bookingId: string): Promise<string> {
  const plan = (await rpc('server_agreement_plan', { p_booking: bookingId }, SR)) as unknown as Plan;
  const by = plan.renter_user_id ?? plan.acting_user_id;
  if (plan.state === 'unsigned' && plan.renter_user_id) {
    // the open agreement prints the booking as it is now (the same facts give the same document: nothing reissued). Once
    // someone has signed it (a driver on their link), it is left as it is: rendering it again would undo their signature;
    // the change becomes a version once the agreement is countersigned (version 1 is what the signed document printed)
    if (plan.any_signed) return 'kept_signed';
    const { openAgreement } = await import('@/server/portal/agreement');
    try { await openAgreement(bookingId, plan.renter_user_id); return 'refreshed'; } catch (e) { console.error('agreement refresh', bookingId, e instanceof Error ? e.message : e); return 'refresh_skipped'; }
  }
  if (plan.state !== 'version' || !by) return plan.state;
  // read as the renter (or, for a renter with no account, as the staff member who added the rental)
  const b = await loadBundle(bookingId, by);
  const kind = plan.kind!;
  const staff = kind === 'pickup' ? plan.pickup?.staff_name : kind === 'return' ? plan.return?.staff_name : null;
  const header: VersionHeader = { version_no: plan.next_no!, previous_no: plan.previous_no!, kind, material: !!plan.material, changes: plan.changes ?? [],
    countersigned_name: staff ?? null, amendment_number: plan.amendment_number ?? null, original_signed_at: plan.original_signed_at ?? null, agreement_number: plan.agreement_number ?? null };
  const renter = b.f.renter?.legal_name ?? b.f.drivers.find((d) => d.role === 'renter')?.full_name ?? '';
  const original = plan.original_signed_at ? `Signed the agreement on ${when(plan.original_signed_at)}` : 'Signed the agreement';
  const awaiting = !!plan.material && (plan.signers?.length ?? 0) > 0;
  const signatures: SignatureRow[] = awaiting
    ? [...(plan.signers ?? []).map((s) => ({ party: s.role === 'renter' ? 'Renter' : 'Additional Driver', name: s.name, signature: 'To sign this version', when: '' })),
      { party: 'CarmaCars', name: '', signature: 'Applied when this version is signed', when: '' }]
    : [{ party: 'Renter', name: renter, signature: plan.amendment_number ? `${original}; signed this change as amendment ${plan.amendment_number}` : `${original} (signature on the signed original; this version is not signed again)`, when: '' },
      { party: kind === 'pickup' ? 'CarmaCars (check-out)' : kind === 'return' ? 'CarmaCars (check-in)' : 'CarmaCars', name: staff ?? '',
        signature: kind === 'pickup' ? 'Countersigned electronically at check-out' : kind === 'return' ? 'Countersigned electronically at check-in' : 'Filed by CarmaCars as a corrected copy', when: when(new Date().toISOString()) }];
  const label = kind === 'pickup' ? 'as picked up' : kind === 'return' ? 'as returned' : kind === 'change' ? 'changed' : 'corrected';
  const cc = await renderCarmaCars(b, { version: header, signatures, title: `Rental agreement ${plan.agreement_number ?? ''}, version ${header.version_no} (${label})`, createdAt: new Date() });
  // a version not signed again carries the signatures of the signed original (the renter's in 16, 17 and 20 with the
  // day, the drivers', the initials); the note "Signed on the original" only when they cannot be read
  const { formSignatures } = await import('@/server/portal/blindspot');
  const stamp = awaiting || !b.bs.template ? null : await formSignatures(bookingId, b).catch((e) => { console.error('blindspot signatures', bookingId, e instanceof Error ? e.message : e); return null; });
  const bs = await renderBlindSpot(b, { title: `Blind Spot rental agreement ${b.f.booking.booking_number}, version ${header.version_no} (${label})`,
    ...(stamp ? { renter: stamp.renter, drivers: stamp.drivers, initials: stamp.initials, signedOn: stamp.signedOn }
      : { note: awaiting ? null : plan.original_signed_at ? `Signed on the original, ${plan.original_signed_at.slice(0, 10)}` : 'Signed on the original' }) });
  const s = await storage();
  const ccSha = await sha256Hex(cc);
  const ccKey = `bookings/${bookingId}/agreement-version-${header.version_no}-${ccSha.slice(0, 16)}.pdf`;
  await s.put('agreements', ccKey, cc, 'application/pdf');
  let blindspot: { path: string; sha256: string } | null = null;
  if (bs) {
    const bsSha = await sha256Hex(bs);
    const bsKey = `bookings/${bookingId}/blindspot-version-${header.version_no}-${bsSha.slice(0, 16)}.pdf`;
    await s.put('agreements', bsKey, bs, 'application/pdf');
    blindspot = { path: bsKey, sha256: bsSha };
  }
  try {
    const r = (await rpc('server_agreement_version_add', { p_booking: bookingId, p: { snapshot_sha: plan.snapshot_sha, kind, template_version: AGREEMENT_TEMPLATE_VERSION,
      blindspot_template_version: b.bs.template?.version ?? null, countersigned_name: staff ?? null, carmacars: { path: ccKey, sha256: ccSha }, blindspot } as unknown as Json }, SR)) as unknown as { recorded: boolean; version_no?: number; status?: string };
    return r.recorded ? `version ${r.version_no} ${r.status}` : 'not recorded';
  } catch (e) {
    // the booking changed while rendering: the job runs again with the new facts (the files of this try are left)
    if (e instanceof DbError && /changed while/.test(e.message)) throw new Error('stale: the booking changed while its agreements were rendered');
    throw e;
  }
}

interface VersionFacts {
  id: string; booking_id: string; version_no: number; kind: string; status: string; changes: Change[]; signed_at: string | null; carmacars_sha256: string; blindspot_sha256: string | null;
  carmacars: { bucket: string; path: string } | null; blindspot: { bucket: string; path: string } | null;
  signers: Array<{ id: string; role: string; name: string; status: string; signed_at: string | null; method: string | null; signature_path: string | null }>;
}

/** A version every signer signed: its signed copies (the signatures page and the certificate added to what they signed). */
export async function runVersionSignedJob(versionId: string): Promise<string> {
  const v = (await rpc('server_agreement_version_facts', { p_version: versionId }, SR)) as unknown as VersionFacts | null;
  if (!v || v.status !== 'signed' || !v.carmacars) return 'nothing';
  const s = await storage();
  const certs = ((await rpc('server_esign_certificate', { p_context: 'agreement_version', p_refs: v.signers.map((g) => g.id) }, SR)) as unknown as CertSigner[]) ?? [];
  const pngs = new Map<string, Uint8Array | null>();
  for (const g of v.signers) pngs.set(g.id, g.signature_path ? await s.get('agreements', g.signature_path).catch(() => null) : null);
  const title = `Signed rental agreement, version ${v.version_no}`;
  const lead = `Version ${v.version_no} of the rental agreement for this booking, signed by each person below. The changes it carries are listed on its first page.`;
  const ccBase = await s.get(v.carmacars.bucket as 'agreements', v.carmacars.path);
  if (!ccBase) throw new Error(`version ${v.version_no}: the CarmaCars document is missing from storage`);
  const rows = v.signers.filter((g) => g.status === 'signed').map((g) => ({ party: g.role === 'renter' ? 'Renter' : 'Additional Driver', name: g.name, when: g.signed_at ? `Signed ${when(g.signed_at)}` : '',
    how: g.method === 'typed' ? 'Typed name (accessibility fallback)' : 'Drawn signature', png: pngs.get(g.id) ?? null }));
  const hashes = [{ label: 'CarmaCars rental agreement, version ' + v.version_no, sha256: v.carmacars_sha256 }, ...(v.blindspot_sha256 ? [{ label: 'Blind Spot rental agreement, version ' + v.version_no, sha256: v.blindspot_sha256 }] : [])];
  const cert = { document: `Rental agreement version ${v.version_no}`, hashes, signers: certs, verifyUrl: verifyUrl(), at: v.signed_at ?? new Date().toISOString() };
  const cc = await appendCertificate(await appendSignaturePage(ccBase, title, lead, rows), cert);
  const ccSha = await sha256Hex(cc);
  const ccKey = `bookings/${v.booking_id}/agreement-version-${v.version_no}-signed.pdf`;
  await s.put('agreements', ccKey, cc, 'application/pdf');
  let blindspot: { path: string; sha256: string } | null = null;
  if (v.blindspot) {
    const base = await s.get(v.blindspot.bucket as 'agreements', v.blindspot.path);
    if (base) {
      const renter = v.signers.find((g) => g.role === 'renter');
      const drivers = v.signers.filter((g) => g.role === 'additional_driver' && pngs.get(g.id)).map((g) => ({ png: pngs.get(g.id)! } as Signature));
      const renterCert = certs.find((c) => c.signer_role === 'renter');
      const plan = renterCert ? (await rpc('server_agreement_plan', { p_booking: v.booking_id }, SR)) as unknown as Plan : null;
      const by = plan?.renter_user_id ?? plan?.acting_user_id;
      const b = by ? await loadBundle(v.booking_id, by).catch(() => null) : null;
      const ini = b ? await initialsOf(b, renterCert) : null;
      const filled = await fillBlindSpot(base, { texts: [], dots: [], covers: [] }, {
        renter: renter ? (pngs.get(renter.id) ? { png: pngs.get(renter.id)! } : { name: renter.name }) : null, drivers,
        initials: ini?.images.get('fees') ?? null, signedOn: renter?.signed_at ?? null, title: `Signed Blind Spot rental agreement, version ${v.version_no}`
      });
      const bs = await appendCertificate(filled.bytes, { ...cert, document: `Blind Spot rental agreement, version ${v.version_no}` });
      const bsSha = await sha256Hex(bs);
      const bsKey = `bookings/${v.booking_id}/blindspot-version-${v.version_no}-signed.pdf`;
      await s.put('agreements', bsKey, bs, 'application/pdf');
      blindspot = { path: bsKey, sha256: bsSha };
    }
  }
  await rpc('server_agreement_version_signed_docs', { p_version: v.id, p: { carmacars: { path: ccKey, sha256: ccSha }, blindspot } as unknown as Json }, SR);
  return `signed copies of version ${v.version_no}`;
}

/** The agreements' queue (agreement_jobs): new versions, signed copies of versions, dispute packs, a few at a time (each
 *  is a PDF or two). A job due in the next seconds is waited for. Run through runAgreementJobs (server/agreement-auto). */
export async function runAgreementQueue(o: { max?: number; deadlineMs?: number; aheadSeconds?: number } = {}): Promise<{ done: number; failed: number; more: boolean }> {
  const start = Date.now();
  let done = 0, failed = 0, more = false;
  for (let n = 0; n < (o.max ?? 2); n++) {
    if (Date.now() - start > (o.deadlineMs ?? 20_000)) { more = true; break; }
    const jobs = (await rpc('server_agreement_jobs_claim', { p_limit: 1, p_ahead_seconds: o.aheadSeconds ?? 0 }, SR)) as unknown as Array<{ kind: string; ref: string; seq: number; due_at: string }>;
    const j = jobs[0];
    if (!j) break;
    const wait = new Date(j.due_at).getTime() - Date.now();
    if (wait > 0) await new Promise((r) => setTimeout(r, Math.min(wait, 15_000)));
    try {
      if (j.kind === 'version') await runVersionJob(j.ref);
      else if (j.kind === 'version_signed') await runVersionSignedJob(j.ref);
      else { const { buildDisputePack } = await import('@/server/agreements/dispute-pack'); await buildDisputePack(j.ref); }
      await rpc('server_agreement_job_done', { p_kind: j.kind, p_ref: j.ref, p_seq: j.seq }, SR);
      done++;
    } catch (e) {
      failed++;
      console.error('agreement job', j.kind, j.ref, e instanceof Error ? e.message : e);
      await rpc('server_agreement_job_fail', { p_kind: j.kind, p_ref: j.ref, p_error: e instanceof Error ? e.message : String(e) }, SR).catch(() => undefined);
    }
    if (n === (o.max ?? 2) - 1) more = true;
  }
  return { done, failed, more };
}
