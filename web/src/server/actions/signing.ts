'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import { CONFIRMATIONS, OWNER_SIGN_STATEMENT, type PacketKey } from '@/features/owner-agreement/model';
import { SIGN_STATEMENT } from '@/features/manual/constants';
import type { PackageInput, PackageResult } from '@/features/signing/PackageSignForm';
import { requestMeta } from '@/server/request';
import { ownerHome, requireOwnerUser } from '@/server/owner/data';
import { queueOwnerSignedCopies, type SignedResult } from '@/server/owner/agreements';
import { currentUser } from '@/server/portal/data';
import { signDocument, storeDrawnSignature } from '@/server/sign-requests';

// Signing packages (migration 0049): one signature, given once, applied to each document of the package by that
// document's own signing function (each keeps its signature record: time, IP address, device, the document's SHA-256 and
// the consent shown for it), then the package itself is recorded with the documents it covered and the time it took.
// The bound part (which documents) comes from the page; every document is checked again by the database (its signer,
// its SHA-256, its state), so a changed list can only fail.
const SR = { role: 'service_role' as const };
const msg = (e: unknown) => (e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong. Try again or call us.');
const invalid = (fieldErrors: Record<string, string>): PackageResult => ({ ok: false, code: 'invalid', message: 'Check the highlighted part.', fieldErrors });
const consentFor = (title: string, all: string[]) => `${SIGN_STATEMENT} I sign "${title}" with the one signature I gave for these ${all.length} documents: ${all.join('; ')}.`;
const SAFE_NEXT = /^\/(owner|investor|va|field|staff|account)(\/[\w/?=&-]*)?$/;

async function recordPackage(userId: string, portal: string, input: PackageInput, docs: Array<{ signature_request_id: string; title: string; consent_text: string }>, consent: string) {
  const meta = await requestMeta();
  try {
    await rpc('server_signing_package_record', { p_by: userId, p: { portal, consent_text: consent, method: input.method, ip: meta.ip, user_agent: meta.userAgent,
      seconds_to_sign: Number.isFinite(input.secondsToSign) ? Math.max(0, Math.min(86_400, Math.round(input.secondsToSign))) : null, documents: docs } }, SR);
  } catch (e) { console.error('signing package record', e); }
}

export interface OwnerPackageSpec {
  packet: Array<{ key: PacketKey; sha: string; title: string }>;
  requests: Array<{ id: string; sha: string; title: string }>;
  next?: string;
}

/** The owner's package: the program agreements and schedules (one call, as before), then each document sent to sign
 *  (Forms A and B, the partner agreement), all with the one signature. */
export async function signOwnerPackage(spec: OwnerPackageSpec, input: PackageInput): Promise<PackageResult> {
  try {
    const user = await requireOwnerUser();
    const home = await ownerHome(user);
    if (!home) return { ok: false, code: 'refused', message: 'This account is not an owner account.' };
    const titles = [...spec.packet.map((d) => d.title), ...spec.requests.map((d) => d.title)];
    if (!titles.length) return { ok: false, code: 'refused', message: 'Nothing to sign.' };
    const enrollment = spec.packet.some((d) => d.key === 'enrollment');
    const fe: Record<string, string> = {};
    if (enrollment && !CONFIRMATIONS.every((c) => input.statements.includes(c.code))) fe.statements = 'Tick the three statements (one tap on "All of these").';
    const initials = (input.initials ?? '').trim().toUpperCase();
    if (enrollment && !/^[A-Z]{1,4}$/.test(initials)) fe.initials = 'Your initials, letters only.';
    if (input.method === 'typed' && !(input.typedName ?? '').trim()) fe.signature = 'Use your name or draw your signature.';
    if (input.method === 'drawn' && !input.drawn) fe.signature = 'Draw your signature in the box.';
    if (Object.keys(fe).length) return invalid(fe);
    const drawnPath = input.method === 'drawn' ? await storeDrawnSignature(user.id, input.drawn!) : null;
    const meta = await requestMeta();
    const signed: Array<{ signature_request_id: string; title: string; consent_text: string }> = [];
    let waiting: string[] = [];
    if (spec.packet.length) {
      const consent = `${OWNER_SIGN_STATEMENT} One signature for: ${titles.join('; ')}.`;
      const res = (await rpc('owner_sign_agreements', { p_owner: home.owner.id, p_by: user.id, p: {
        typed_name: input.method === 'typed' ? input.typedName!.trim() : null, drawn_signature: drawnPath, ip: meta.ip, user_agent: meta.userAgent, consent_text: consent,
        initials: enrollment ? Object.fromEntries(CONFIRMATIONS.map((c) => [c.code, initials])) : null,
        documents: spec.packet.map((d) => ({ key: d.key, sha256: d.sha })) } }, SR)) as unknown as SignedResult;
      if (res.complete === false) waiting = res.waiting_for ?? [];
      else { try { await queueOwnerSignedCopies(home.owner.id, user.id, res); } catch (e) { console.error('owner signed copy job', e); } }
      for (const d of res.signed) {
        const title = spec.packet.find((p) => p.key === d.key)?.title ?? d.key;
        signed.push({ signature_request_id: d.signature_request_id, title, consent_text: consentFor(title, titles) });
      }
    }
    for (const r of spec.requests) {
      const out = await signDocument(user.id, { id: r.id, sha: r.sha, typedName: input.method === 'typed' ? input.typedName : undefined, drawnPath: drawnPath ?? undefined,
        consent: consentFor(r.title, titles) });
      signed.push({ signature_request_id: out.signature_request_id, title: r.title, consent_text: consentFor(r.title, titles) });
    }
    await recordPackage(user.id, home.kind === 'partner' ? 'partner' : 'owner', input, signed, `One signature for ${titles.length} document${titles.length > 1 ? 's' : ''}: ${titles.join('; ')}.`);
    for (const p of ['/owner', '/owner/sign', '/owner/documents', '/owner/partner-agreement']) revalidatePath(p);
    return { ok: true, data: { signed: signed.length, next: spec.next && SAFE_NEXT.test(spec.next) ? spec.next : '/owner?signed=1',
      message: waiting.length
        ? `Signed. The agreements take effect when every Owner has signed: we sent ${waiting.join(' and ')} their own link. CarmaCars countersigns then, and the signed copies go to Documents.`
        : `Signed ${signed.length > 1 ? `all ${signed.length} documents` : 'the document'}. CarmaCars countersigned. Your signed copies are being made now: they appear in Documents within a few minutes and we email them to you.` } };
  } catch (e) { return { ok: false, code: 'refused', message: msg(e) }; }
}

export interface PortalPackageSpec { requests: Array<{ id: string; sha: string; title: string; doc_type: string }>; portal: 'investor' | 'staff'; next?: string }

/** The documents an Admin sent to an investor or a staff member: every open one, signed with the one signature. */
export async function signPortalPackage(spec: PortalPackageSpec, input: PackageInput): Promise<PackageResult> {
  try {
    const user = await currentUser();
    if (!user) return { ok: false, code: 'refused', message: 'Sign in first.' };
    if (!spec.requests.length) return { ok: false, code: 'refused', message: 'Nothing to sign.' };
    const investment = spec.requests.some((r) => r.doc_type === 'investment_agreement');
    const fe: Record<string, string> = {};
    if (investment && !input.legalAdvice) fe.advice = 'Say whether you got independent legal advice.';
    if (investment && !/^[A-Za-z]{1,4}$/.test((input.initials ?? '').trim())) fe.initials = 'Your initials, letters only.';
    if (input.method === 'drawn' && !input.drawn) fe.signature = 'Draw your signature in the box.';
    if (input.method === 'typed' && !(input.typedName ?? '').trim()) fe.signature = 'Use your name or draw your signature.';
    if (Object.keys(fe).length) return invalid(fe);
    const drawnPath = input.method === 'drawn' ? await storeDrawnSignature(user.id, input.drawn!) : null;
    const titles = spec.requests.map((r) => r.title);
    const signed: Array<{ signature_request_id: string; title: string; consent_text: string }> = [];
    for (const r of spec.requests) {
      const inv = r.doc_type === 'investment_agreement';
      const out = await signDocument(user.id, { id: r.id, sha: r.sha, typedName: input.method === 'typed' ? input.typedName : undefined, drawnPath: drawnPath ?? undefined,
        consent: consentFor(r.title, titles), legalAdvice: inv ? input.legalAdvice : undefined, adviser: inv ? input.adviser : undefined, initials: inv ? input.initials : undefined });
      signed.push({ signature_request_id: out.signature_request_id, title: r.title, consent_text: consentFor(r.title, titles) });
    }
    await recordPackage(user.id, spec.portal, input, signed, `One signature for ${titles.length} document${titles.length > 1 ? 's' : ''}: ${titles.join('; ')}.`);
    for (const p of ['/investor', '/investor/sign', '/staff', '/staff/sign', '/staff/field', '/staff/field/sign']) revalidatePath(p);
    return { ok: true, data: { signed: signed.length, next: spec.next && SAFE_NEXT.test(spec.next) ? spec.next : undefined,
      message: `Signed ${signed.length > 1 ? `all ${signed.length} documents` : 'the document'}. The signed ${signed.length > 1 ? 'copies appear' : 'copy appears'} below within a few minutes.` } };
  } catch (e) { return { ok: false, code: 'refused', message: msg(e) }; }
}
