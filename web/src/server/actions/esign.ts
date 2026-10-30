'use server';
import { DbError, rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { env } from '@/lib/env';
import type { ActionResult } from '@/features/forms/schemas';
import { storage } from '@/integrations/storage';
import { phoneLine } from '@/integrations/phone';
import { requestMeta } from '@/server/request';
import { readToken, sha256Hex } from '@/server/links';
import { currentUser, findBooking } from '@/server/portal/data';
import { rolesOf } from '@/server/door';
import { CONSENTS, type ConsentCode } from '@/features/agreement/extra';
import { DOC_CONSENTS } from '@/features/signing/terms';
import { TITLES, type PacketKey } from '@/features/owner-agreement/model';
import type { EsignContext, EsignView } from '@/features/signing/types';

// The signing session of every signature (migration 0154): the renter's own (remote), an additional driver's (their
// link), one collected in person on a staff member's device, an amendment, a new version; since 0193 every other
// document signed on the site (the owner's agreements, schedules and forms, the partner, investment and staff
// agreements, an updated Vehicle Schedule) and another Owner's link. Each action
// finds the signer from the records (never from the page), then the database checks and records the step. The one-time
// code is made here, sent by text (the CarmaCars number) or by email, and only its hash is kept.
const SR = { role: 'service_role' as const };
type R<T = null> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

interface Resolved {
  context: 'rental_agreement' | 'amendment' | 'agreement_version' | 'documents' | 'owner_cosigner'; signer_ref: string; booking_id: string | null; method: 'remote' | 'in_person';
  collected_by: string | null; documents: Array<{ title: string; sha256: string; kind?: string; ref?: string }>; owner_id?: string | null; role?: string;
}
interface CosignFacts { cosigner: { id: string; status: string }; owner: { id: string }; documents: Array<{ key: PacketKey; sha256: string }> }
const cosignFacts = async (token: string) => (/^[0-9a-f]{64}$/.test(token) ? ((await rpc('server_owner_cosigner_facts', { p_token: token }, SR)) as unknown as CosignFacts | null) : null);

async function resolve(ctx: EsignContext): Promise<Resolved> {
  if (ctx.kind === 'documents') {
    // the database checks each document: open, this signer's, the SHA-256 shown (app.esign_start_documents)
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    if (!ctx.docs.length) throw new Error('Nothing to sign here.');
    let owner: string | null = null;
    if (ctx.docs.some((d) => d.kind === 'packet')) {
      const { ownerHome } = await import('@/server/owner/data');
      owner = (await ownerHome(user))?.owner.id ?? null;
      if (!owner) throw new Error('This account is not an owner account.');
    }
    return { context: 'documents', signer_ref: user.id, booking_id: null, method: 'remote', collected_by: null, owner_id: owner, role: ctx.role,
      documents: ctx.docs.map((d) => ({ title: d.title.slice(0, 160), sha256: d.sha.toLowerCase(), kind: d.kind, ref: d.ref })) };
  }
  if (ctx.kind === 'cosigner') {
    const f = await cosignFacts(ctx.token);
    if (!f || f.cosigner.status !== 'pending') throw new Error('Nothing is waiting for your signature.');
    return { context: 'owner_cosigner', signer_ref: f.cosigner.id, booking_id: null, method: 'remote', collected_by: null, owner_id: f.owner.id,
      documents: f.documents.map((d) => ({ title: TITLES[d.key] ?? d.key, sha256: d.sha256, kind: 'packet', ref: d.key })) };
  }
  if (ctx.kind === 'renter') {
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const b = await findBooking(user, ctx.number);
    if (!b) throw new Error('Booking not found');
    const g = (await rpc('server_esign_signer', { p_booking: b.id, p_user: user.id }, SR)) as unknown as { signer_id: string; documents: Resolved['documents'] } | null;
    if (!g) throw new Error('There is no agreement waiting for your signature. Reload the page.');
    return { context: 'rental_agreement', signer_ref: g.signer_id, booking_id: b.id, method: 'remote', collected_by: null, documents: g.documents };
  }
  if (ctx.kind === 'driver') {
    const t = await readToken<{ s: string; v?: number }>('driver-sign', ctx.token);
    if (!t || (await rpc('server_driver_link_valid', { p_signer: t.s, p_version: t.v ?? 1 }, SR)) !== true) throw new Error('This link has expired. Ask the renter to send a new one.');
    const g = (await rpc('server_esign_signer', { p_booking: null as unknown as string, p_user: null as unknown as string, p_signer: t.s }, SR)) as unknown as { signer_id: string; booking_id: string; documents: Resolved['documents'] } | null;
    if (!g) throw new Error('This agreement is no longer waiting for your signature.');
    return { context: 'rental_agreement', signer_ref: g.signer_id, booking_id: g.booking_id, method: 'remote', collected_by: null, documents: g.documents };
  }
  if (ctx.kind === 'in_person') {
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const roles = await rolesOf(user.id);
    if (!roles.admin && !roles.va && !roles.field) throw new Error('Only staff collect signatures in person.');
    const g = (await rpc('server_esign_signer', { p_booking: ctx.booking, p_user: null as unknown as string, p_signer: ctx.signer }, SR)) as unknown as { signer_id: string; booking_id: string; documents: Resolved['documents'] } | null;
    if (!g) throw new Error('That signer has nothing to sign on this booking.');
    return { context: 'rental_agreement', signer_ref: g.signer_id, booking_id: g.booking_id, method: 'in_person', collected_by: user.id, documents: g.documents };
  }
  if (ctx.kind === 'amendment') {
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    const b = await findBooking(user, ctx.number);
    if (!b || !b.change_requests.some((c) => c.id === ctx.requestId)) throw new Error('Not found');
    const { changeFacts, openAmendment } = await import('@/server/portal/change');
    const f = await changeFacts(ctx.requestId, user.id);
    if (!f.open) throw new Error('This change is no longer waiting for your answer.');
    const a = await openAmendment(f, user.id);
    return { context: 'amendment', signer_ref: a.id, booking_id: b.id, method: 'remote', collected_by: null, documents: [{ title: `Amendment ${a.number}`, sha256: a.sha }] };
  }
  // a new version of the agreement: the signer's own link (or opened on a staff member's device)
  const link = (await rpc('server_agreement_version_link', { p_token: ctx.token }, SR)) as unknown as { signer_id: string; status: string; booking: { id: string }; version: { status: string; carmacars_sha256: string; blindspot_sha256: string | null; version_no: number } } | null;
  if (!link || link.status !== 'waiting' || link.version.status !== 'awaiting_signature') throw new Error('This version of the agreement is no longer waiting for your signature.');
  let collected: string | null = null;
  if (ctx.inPerson) {
    const user = await currentUser();
    const roles = user ? await rolesOf(user.id) : null;
    if (!user || !roles || (!roles.admin && !roles.va && !roles.field)) throw new Error('Only staff collect signatures in person.');
    collected = user.id;
  }
  return { context: 'agreement_version', signer_ref: link.signer_id, booking_id: link.booking.id, method: collected ? 'in_person' : 'remote', collected_by: collected,
    documents: [{ title: `CarmaCars rental agreement, version ${link.version.version_no}`, sha256: link.version.carmacars_sha256 },
      ...(link.version.blindspot_sha256 ? [{ title: `Blind Spot rental agreement, version ${link.version.version_no}`, sha256: link.version.blindspot_sha256 }] : [])] };
}

/** The session of this signer and these documents (the same one when they come back within two hours). */
export async function esignStart(ctx: EsignContext): Promise<R<EsignView>> {
  try {
    const r = await resolve(ctx);
    const meta = await requestMeta();
    const v = (await rpc('server_esign_start', { p: { context: r.context, signer_ref: r.signer_ref, booking_id: r.booking_id, method: r.method, collected_by: r.collected_by,
      documents: r.documents, owner_id: r.owner_id ?? null, role: r.role ?? null, ip: meta.ip ?? null, user_agent: meta.userAgent } as unknown as Json }, SR)) as unknown as EsignView;
    return { ok: true, data: v };
  } catch (e) { return fail(e); }
}

/** Is this session the signer's? Each step checks it again from the records (a session id alone is not enough), without
 *  rendering anything. */
async function own(ctx: EsignContext, session: string): Promise<EsignView> {
  const o = (await rpc('server_esign_owner', { p_session: session }, SR)) as unknown as { signer_ref: string; context: string; booking_id: string | null } | null;
  if (!o) throw new Error('This signing has ended: reload the page');
  let ok = false;
  if (ctx.kind === 'driver') {
    const t = await readToken<{ s: string }>('driver-sign', ctx.token);
    ok = !!t && t.s === o.signer_ref && o.context === 'rental_agreement';
  } else if (ctx.kind === 'cosigner') {
    const f = await cosignFacts(ctx.token);
    ok = !!f && f.cosigner.id === o.signer_ref && o.context === 'owner_cosigner';
  } else if (ctx.kind === 'documents') {
    const user = await currentUser();
    ok = !!user && user.id === o.signer_ref && o.context === 'documents';
  } else if (ctx.kind === 'version') {
    const link = (await rpc('server_agreement_version_link', { p_token: ctx.token }, SR)) as unknown as { signer_id: string } | null;
    ok = !!link && link.signer_id === o.signer_ref && o.context === 'agreement_version';
  } else {
    const user = await currentUser();
    if (user && ctx.kind === 'in_person') {
      const roles = await rolesOf(user.id);
      ok = (roles.admin || roles.va || roles.field) && o.booking_id === ctx.booking && o.signer_ref === ctx.signer && o.context === 'rental_agreement';
    } else if (user && (ctx.kind === 'renter' || ctx.kind === 'amendment')) {
      const b = await findBooking(user, ctx.number);
      ok = !!b && b.id === o.booking_id && o.context === (ctx.kind === 'renter' ? 'rental_agreement' : 'amendment')
        && (ctx.kind === 'renter' || b.change_requests.some((c) => c.id === ctx.requestId));
    }
  }
  if (!ok) throw new Error('This signing has ended: reload the page');
  return (await rpc('server_esign_view', { p_session: session }, SR)) as unknown as EsignView;
}

const fakeLine = () => env().QUO_PROVIDER !== 'quo' && env().APP_ENV !== 'production';

/** A one-time code by text or by email. Locally (the fake text line) the code is shown on the page for the tests. */
export async function esignSendCode(ctx: EsignContext, session: string, channel: 'sms' | 'email'): Promise<R<EsignView & { devCode?: string }>> {
  try {
    await own(ctx, session);
    const code = String(crypto.getRandomValues(new Uint32Array(1))[0]! % 1_000_000).padStart(6, '0');
    const meta = await requestMeta();
    const to = (await rpc('server_esign_code_set', { p_session: session, p_channel: channel, p_hash: await sha256Hex(new TextEncoder().encode(`${session}:${code}`)), p_ip: meta.ip ?? undefined, p_user_agent: meta.userAgent }, SR)) as unknown as
      { to: string; from: string | null; name: string; booking_id: string | null };
    if (channel === 'sms') {
      if (!to.from) throw new Error('The CarmaCars number is not set (Site settings, Phone): use the email instead.');
      const res = await phoneLine().sendText({ from: to.from, to: to.to, body: `CarmaCars signing code: ${code}. It expires in 10 minutes. Never share it; we never ask for it by phone.` });
      if (!res.ok) throw new Error(`The text could not be sent: ${res.error ?? 'refused'}. Use the email instead.`);
    } else {
      await rpc('server_esign_code_email', { p_session: session, p_code: code }, SR);
    }
    const v = (await rpc('server_esign_view', { p_session: session }, SR)) as unknown as EsignView;
    return { ok: true, data: fakeLine() ? { ...v, devCode: code } : v };
  } catch (e) { return fail(e); }
}

export async function esignCheckCode(ctx: EsignContext, session: string, code: string): Promise<R<EsignView & { wrong?: boolean }>> {
  try {
    await own(ctx, session);
    const meta = await requestMeta();
    const v = (await rpc('server_esign_code_check', { p_session: session, p_hash: await sha256Hex(new TextEncoder().encode(`${session}:${code.replace(/\D/g, '')}`)), p_ip: meta.ip ?? undefined, p_user_agent: meta.userAgent }, SR)) as unknown as EsignView & { wrong?: boolean };
    return v.wrong ? { ok: false, code: 'invalid', message: 'That code does not match. Check it and try again, or ask for a new one.', fieldErrors: { code: 'That code does not match.' } } : { ok: true, data: v };
  } catch (e) { return fail(e); }
}

function pngBytes(dataUrl: string, min = 120): Uint8Array | null {
  const m = /^data:image\/png;base64,([A-Za-z0-9+/=]+)$/.exec(dataUrl ?? '');
  if (!m) return null;
  const bin = Uint8Array.from(atob(m[1]!), (c) => c.charCodeAt(0));
  const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  return bin.length > min && bin.length < 400_000 && sig.every((v, i) => bin[i] === v) ? bin : null;
}

export type EsignStep =
  | { kind: 'viewed' } | { kind: 'document_opened'; title: string }
  | { kind: 'initial'; code: string; png?: string; typed?: string }
  | { kind: 'initial_clear'; code: string }
  | { kind: 'consent'; code: ConsentCode }
  | { kind: 'geolocation'; lat: number; lng: number; accuracy: number }
  | { kind: 'signature'; png?: string; typed?: string };

/** One step of the signer. Drawn initials and the signature are stored privately; the step keeps their key. */
export async function esignStep(ctx: EsignContext, session: string, step: EsignStep): Promise<R<EsignView & { path?: string }>> {
  try {
    await own(ctx, session);
    const meta = await requestMeta();
    let detail: Record<string, unknown> = {};
    let path: string | undefined;
    const store = async (png: Uint8Array, what: string) => {
      const key = `esign/${session}/${what}-${crypto.randomUUID()}.png`;
      await (await storage()).put('agreements', key, png, 'image/png');
      return key;
    };
    if (step.kind === 'initial') {
      if (step.png) { const b = pngBytes(step.png, 80); if (!b) throw new Error('Initial in the box.'); path = await store(b, `initials-${step.code}`); detail = { code: step.code, path }; }
      else detail = { code: step.code, typed: true, text: (step.typed ?? '').slice(0, 10) };
    } else if (step.kind === 'initial_clear') detail = { code: step.code };
    else if (step.kind === 'consent') {
      const texts: Record<string, string> = ctx.kind === 'documents' || ctx.kind === 'cosigner' ? DOC_CONSENTS : CONSENTS;
      if (!texts[step.code]) throw new Error('Unknown consent.');
      detail = { code: step.code, text: texts[step.code] };
    }
    else if (step.kind === 'geolocation') detail = { lat: step.lat, lng: step.lng, accuracy: step.accuracy };
    else if (step.kind === 'document_opened') detail = { title: step.title.slice(0, 120) };
    else if (step.kind === 'signature') {
      if (step.png) { const b = pngBytes(step.png); if (!b) throw new Error('Please sign in the box.'); path = await store(b, 'signature'); detail = { method: 'drawn', path }; }
      else detail = { method: 'typed', path: (step.typed ?? '').trim().slice(0, 120) };
    }
    const v = (await rpc('server_esign_step', { p_session: session, p_kind: step.kind, p_detail: detail as unknown as Json, p_ip: meta.ip ?? undefined, p_user_agent: meta.userAgent }, SR)) as unknown as EsignView;
    return { ok: true, data: { ...v, path } };
  } catch (e) { return fail(e); }
}

/** A wrong mobile number while signing (migration 0183): the signed-in renter, or the staff member collecting the
 *  signature in person, corrects it; the next code goes there and the renter's profile keeps it. */
export async function esignSetMobile(ctx: EsignContext, session: string, phone: string): Promise<R<EsignView>> {
  try {
    if (ctx.kind !== 'renter' && ctx.kind !== 'amendment' && ctx.kind !== 'in_person') throw new Error('Ask the renter or CarmaCars to correct the number for you.');
    await own(ctx, session);
    const { toE164 } = await import('@/features/auth/phone');
    const e164 = toE164(phone);
    if (!e164) throw new Error('Enter a Canadian or US mobile number.');
    const user = await currentUser();
    const v = (await rpc('server_esign_set_mobile', { p_session: session, p_mobile: e164, p_by: user!.id }, SR)) as unknown as EsignView;
    return { ok: true, data: v };
  } catch (e) { return fail(e); }
}
