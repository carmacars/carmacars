import 'server-only';
import { rpc } from '@/lib/db/repo';
import { storage } from '@/integrations/storage';
import { sha256Hex } from '@/server/links';
import { when, type AgreementFacts } from '@/features/agreement/model';
import { layout, type BlindSpotFacts } from '@/features/blindspot/layout';
import { fillBlindSpot, type Signature } from '@/features/blindspot/fill';

// The second rental agreement of a booking (migration 0127): Blind Spot Car Rental's own agreement, filled from the
// booking and stored beside CarmaCars' rental agreement when that one opens; signed with the same one signature; its
// signed copy (the renter's signature in boxes 16, 17 and 20, and a signature record page) stored once the rental
// agreement is countersigned. Nothing happens until an Admin has uploaded and checked the template (Settings > Forms).
const SR = { role: 'service_role' as const };

type Extra = BlindSpotFacts['extra'];
export interface BlindSpotExtra extends Extra {
  multi_day_rate_cents: number | null;
  template: { id: string; version: string; file_key: string; sha256: string } | null;
  rep: { name: string; full_name: string | null; signature_key: string | null; signature_sha256: string | null };
}
export interface Companion {
  id: string; status: 'open' | 'signed' | 'completed'; document_id: string; document_sha256: string; signed_document_id: string | null; template_id: string;
  renter_signed_at: string | null; agreement_number: string; agreement_status: string; document: { bucket: string; path: string } | null;
  renter_record: { signer_name: string; method: string; signed_at: string; ip_address: string | null; user_agent: string | null; provider_signature: string | null; typed_name: string | null } | null;
}

export async function companionOf(bookingId: string): Promise<Companion | null> {
  return (await rpc('server_agreement_companion', { p_booking: bookingId }, SR)) as unknown as Companion | null;
}
async function extraOf(bookingId: string, by: string): Promise<BlindSpotExtra> {
  return (await rpc('server_blindspot_facts', { p_booking: bookingId, p_by: by }, SR)) as unknown as BlindSpotExtra;
}

export function blindSpotFacts(f: AgreementFacts, x: BlindSpotExtra): BlindSpotFacts {
  return { booking: { ...f.booking, multi_day_rate_cents: x.multi_day_rate_cents }, renter: f.renter, drivers: f.drivers, vehicle: f.vehicle, lines: f.lines, card: f.card,
    extra: { mailing: x.mailing, hst_number: x.hst_number, fleet_number: x.fleet_number, odometer_out_km: x.odometer_out_km, insurer: x.insurer } };
}

// The template is 2.5 MB: kept in memory by its SHA-256 between renders of the same Worker; checked against the hash
// recorded when it was uploaded.
let cached: { sha: string; bytes: Uint8Array } | null = null;
export async function templateBytes(t: { file_key: string; sha256: string }): Promise<Uint8Array> {
  if (cached?.sha === t.sha256) return cached.bytes;
  const bytes = await (await storage()).get('documents', t.file_key);
  if (!bytes) throw new Error('The Blind Spot template file is missing from storage (Admin > Settings > Forms: upload it again)');
  if ((await sha256Hex(bytes)) !== t.sha256) throw new Error('The Blind Spot template file does not match the one checked (Admin > Settings > Forms: upload it again)');
  cached = { sha: t.sha256, bytes };
  return bytes;
}

/** The authorized company representative: the uploaded signature image, or the name written in the script hand. */
export async function companySignature(rep: { name: string; signature_key: string | null }): Promise<Signature> {
  if (rep.signature_key) {
    const png = await (await storage()).get('documents', rep.signature_key).catch(() => null);
    if (png) return { png };
  }
  return { name: rep.name || 'Ahmad' };
}

/** Renders and stores the second agreement for the booking's open rental agreement. Returns its id, or null when the
 *  template is not in use (or the rental agreement was signed before it was). The same document returns the same row. */
export async function openCompanion(bookingId: string, by: string): Promise<string | null> {
  const { agreementFacts } = await import('@/server/portal/agreement');
  const [f, x, cur] = await Promise.all([agreementFacts(bookingId, by), extraOf(bookingId, by), companionOf(bookingId)]);
  if (!x.template) return null;
  if (cur && cur.status !== 'open') return cur.id;
  const r = await fillBlindSpot(await templateBytes(x.template), layout(blindSpotFacts(f, x)), {
    company: await companySignature(x.rep), title: `Blind Spot rental agreement ${f.booking.booking_number}`
  });
  const sha = await sha256Hex(r.bytes);
  if (cur && cur.document_sha256 === sha && cur.template_id === x.template.id) return cur.id;
  const key = `bookings/${bookingId}/blindspot-${sha.slice(0, 16)}.pdf`;
  await (await storage()).put('agreements', key, r.bytes, 'application/pdf');
  return (await rpc('server_open_agreement_companion', { p_booking: bookingId, p_by: by, p_template: x.template.id, p_storage_path: key, p_sha256: sha }, SR)) as unknown as string | null;
}

/** Never in the way of the rental agreement: a second agreement that cannot be made now is made on the next opening. */
export async function openCompanionQuietly(bookingId: string, by: string): Promise<void> {
  try { await openCompanion(bookingId, by); } catch (e) { console.error('blindspot agreement', bookingId, e instanceof Error ? e.message : e); }
}

/** After the rental agreement is countersigned: the signed copy of the second agreement, stored once. */
export async function attachCompanionSigned(bookingId: string, by: string): Promise<void> {
  const c = await companionOf(bookingId);
  if (!c || c.status !== 'signed' || c.agreement_status !== 'completed' || !c.document) return;
  const s = await storage();
  const unsigned = await s.get(c.document.bucket as 'agreements', c.document.path);
  if (!unsigned) throw new Error(`The Blind Spot agreement of booking ${bookingId} is missing from storage`);
  const r = c.renter_record;
  let renter: Signature | null = null;
  if (r?.method === 'drawn' && r.provider_signature) renter = { png: await s.get('agreements', r.provider_signature).catch(() => null) };
  if (!renter?.png) renter = { name: r?.typed_name ?? r?.signer_name ?? null };
  const x = await extraOf(bookingId, by);
  const lines: Array<[string, string]> = [
    ['Document', `Blind Spot Car Rental agreement, filled for this booking (template ${x.template?.version ?? ''})`],
    ['Signed with', `the same signature as CarmaCars rental agreement ${c.agreement_number}`],
    ['Unsigned document SHA-256', c.document_sha256],
    ...(r ? [[`Renter: ${r.signer_name}`, `${when(r.signed_at)}; method ${r.method}${r.ip_address ? `; IP address ${r.ip_address}` : ''}${r.user_agent ? `; device ${r.user_agent}` : ''}`] as [string, string]] : []),
    ['Signed in boxes', '16 (Loss Damage Waiver), 17 (tickets, violations and tolls) and 20 (the terms of pages 1 and 2)'],
    ['Authorized company representative', `${x.rep.full_name || x.rep.name}, box 21 (${x.rep.signature_key ? 'signature image on file' : 'name written for the representative'})`]
  ];
  const out = await fillBlindSpot(unsigned, { texts: [], dots: [], covers: [] }, { renter, record: { title: 'Signature record', lines }, title: `Signed Blind Spot rental agreement ${c.agreement_number}` });
  const sha = await sha256Hex(out.bytes);
  const key = `bookings/${bookingId}/blindspot-${c.agreement_number}-signed.pdf`;
  await s.put('agreements', key, out.bytes, 'application/pdf');
  await rpc('server_attach_companion_signed', { p_companion: c.id, p_storage_path: key, p_sha256: sha }, SR);
}
