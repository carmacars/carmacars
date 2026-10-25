'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { consents, CONSENT_VERSION, consentLine, SIGN_STATEMENT } from '@/features/agreement/model';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { storage } from '@/integrations/storage';
import { requestMeta } from '@/server/request';
import { enqueuePdfJobs } from '@/server/pdf-jobs';
import { chargeAddedRental } from '@/server/portal/added-charge';
import { sha256Hex } from '@/server/links';
import type { SigningState } from '@/features/handover/types';

// Signing on the spot (migration 0130): a staff member hands their device to the renter or an additional driver, who
// reads the agreements and signs; the database records the same signature as remote signing plus who collected it, the
// device and the identity check (app.sign_in_person). The staff member may photograph the licence first.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown, code = 'refused'): R<never> => ({ ok: false, code, message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : String(e) });

async function staff() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  const roles = await rolesOf(user.id);
  if (!roles.admin && !roles.va && !roles.field) throw new Error('Only staff collect signatures in person.');
  const aal = await sessionAal();
  if (roles.two_step_required && aal !== 'aal2') throw new Error('Two-step sign-in is required.');
  return { user, aal };
}

function pngBytes(dataUrl: string): Uint8Array | null {
  const m = /^data:image\/png;base64,([A-Za-z0-9+/=]+)$/.exec(dataUrl ?? '');
  if (!m) return null;
  const bin = Uint8Array.from(atob(m[1]!), (c) => c.charCodeAt(0));
  const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  return bin.length > 200 && bin.length < 400_000 && sig.every((v, i) => bin[i] === v) ? bin : null;
}

export interface SignNowInput {
  booking: string; signer: string; sha: string; companionSha?: string | null; consents: string[]; typedName?: string; drawn?: string; device?: string;
  identity: { name_confirmed: boolean; licence_seen: boolean }; refresh?: string[];
  /** 0154: the signing session and the drawn signature it stored */ session?: string; drawnPath?: string;
}

export async function signInPerson(input: SignNowInput): Promise<R<{ role: string; declined: string | null }>> {
  try {
    const { user, aal } = await staff();
    const s = await door<SigningState>(user.id, 'ops_read', 'in_person_signing', { booking: input.booking }, aal);
    const g = s.signers.find((x) => x.id === input.signer);
    if (!g) return fail('That signer is not on this booking.');
    const need = consents().filter((c) => g.role === 'renter' || c.n <= 3);
    const ticked = new Set(input.consents ?? []);
    if (!need.every((c) => ticked.has(c.code))) return { ok: false, code: 'invalid', message: `Tick the ${need.length === 4 ? 'four' : 'three'} statements to sign.`, fieldErrors: { consents: 'Tick every statement.' } };
    if (!input.identity?.name_confirmed || !input.identity?.licence_seen) return { ok: false, code: 'invalid', message: 'Confirm the name and that you saw the original licence.' };
    let drawn: string | undefined = input.drawnPath && /^esign\/[0-9a-f-]{36}\/signature-[0-9a-f-]{36}\.png$/.test(input.drawnPath) ? input.drawnPath : undefined;
    if (!drawn && input.drawn) {
      const png = pngBytes(input.drawn);
      if (!png) return { ok: false, code: 'invalid', message: 'Please sign in the box.', fieldErrors: { signature: 'Please sign in the box.' } };
      drawn = g.role === 'renter' ? `bookings/${s.booking_id}/signatures/renter-in-person-${crypto.randomUUID()}.png` : `drivers/${g.id}/signature-in-person-${crypto.randomUUID()}.png`;
      await (await storage()).put('agreements', drawn, png, 'image/png');
    } else if (!drawn && !(input.typedName ?? '').trim()) {
      return { ok: false, code: 'invalid', message: 'Sign by drawing or by using the name on file.', fieldErrors: { signature: 'Sign by drawing or with the name.' } };
    }
    const meta = await requestMeta();
    await door(user.id, 'ops_do', 'sign_in_person', {
      booking: s.booking_id, signer: g.id, typed_name: drawn ? undefined : input.typedName?.trim(), drawn, sha: input.sha, companion_sha: input.companionSha ?? undefined,
      consent_text: SIGN_STATEMENT, consents: need.map((c) => ({ code: c.code, version: CONSENT_VERSION, text: consentLine(c) })),
      device: (input.device ?? '').slice(0, 200) || meta.userAgent, ip: meta.ip ?? undefined, user_agent: meta.userAgent, identity: input.identity
    }, aal);
    // a rental staff added by hand: charged on signing with the saved card and its signed copy filed now, as when the
    // renter signs in their portal (0053, 0077)
    let declined: string | null = null;
    if (g.role === 'renter' && s.added && s.renter_user_id) {
      declined = await chargeAddedRental(s.booking_id, s.booking_number, s.renter_user_id);
      try { await enqueuePdfJobs([{ kind: 'renter_signed_copy', ref: s.booking_id, user_id: s.renter_user_id }]); } catch (e) { console.error('signed copy job', e); }
    }
    for (const p of input.refresh ?? []) revalidatePath(p);
    return { ok: true, data: { role: g.role, declined } };
  } catch (e) { return fail(e); }
}

/** The licence photographed on the spot by the staff member (front, back or the selfie), stored privately. */
export async function staffLicenceUpload(form: FormData): Promise<R> {
  try {
    const { user, aal } = await staff();
    const booking = String(form.get('booking') ?? ''); const driver = String(form.get('driver') ?? ''); const kind = String(form.get('kind') ?? '');
    const file = form.get('file');
    if (!/^[0-9a-f-]{36}$/.test(booking) || !/^[0-9a-f-]{36}$/.test(driver) || !['licence_front', 'licence_back', 'selfie'].includes(kind)) return fail('Unknown upload.');
    if (!(file instanceof Blob) || file.size === 0 || file.size > 10 * 1024 * 1024) return fail('The photo must be under 10 MB.');
    const bytes = new Uint8Array(await file.arrayBuffer());
    const jpg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
    const png = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
    if (!jpg && !png) return fail('That file is not a photo.');
    const key = `staff/${booking}/${kind}-${driver}-${crypto.randomUUID()}.${jpg ? 'jpg' : 'png'}`;
    const s = await storage();
    await s.put('identity', key, bytes, jpg ? 'image/jpeg' : 'image/png');
    try {
      await door(user.id, 'ops_do', 'staff_licence_register', { booking, driver, kind, path: key, sha256: await sha256Hex(bytes), mime: jpg ? 'image/jpeg' : 'image/png' }, aal);
    } catch (e) { await s.remove('identity', key).catch(() => undefined); throw e; }
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}
