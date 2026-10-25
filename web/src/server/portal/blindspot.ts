import 'server-only';
import { rpc } from '@/lib/db/repo';
import { storage } from '@/integrations/storage';
import { sha256Hex } from '@/server/links';
import { when } from '@/features/agreement/model';
import type { Signature } from '@/features/blindspot/fill';
import { companySignature, initialsOf, loadBundle, renderBlindSpot, templateBytes, verifyUrl, type BlindSpotExtra, type Bundle } from '@/server/agreements/bundle';
import type { Certificate } from '@/features/signing/certificate';

// The second rental agreement of a booking (migration 0127): Blind Spot Car Rental's own agreement, filled from the
// booking and stored beside CarmaCars' rental agreement when that one opens; signed with the same one signature; its
// signed copy (the renter's signature in boxes 16, 17 and 20, each driver's in box 10, the renter's initials, a
// signature record page and the certificate of completion, 0154) stored once the rental agreement is countersigned.
// Nothing happens until an Admin has uploaded and checked the template (Settings > Forms).
const SR = { role: 'service_role' as const };

export { companySignature, templateBytes };
export type { BlindSpotExtra };
export interface Companion {
  id: string; status: 'open' | 'signed' | 'completed'; document_id: string; document_sha256: string; signed_document_id: string | null; template_id: string;
  renter_signed_at: string | null; agreement_number: string; agreement_status: string; document: { bucket: string; path: string } | null;
  renter_record: { signer_name: string; method: string; signed_at: string; ip_address: string | null; user_agent: string | null; provider_signature: string | null; typed_name: string | null } | null;
}

export async function companionOf(bookingId: string): Promise<Companion | null> {
  return (await rpc('server_agreement_companion', { p_booking: bookingId }, SR)) as unknown as Companion | null;
}

/** Renders and stores the second agreement for the booking's open rental agreement. Returns its id, or null when the
 *  template is not in use (or the rental agreement was signed before it was). The same document returns the same row. */
export async function openCompanion(bookingId: string, by: string, bundle?: Bundle): Promise<string | null> {
  const [b, cur] = await Promise.all([bundle ? Promise.resolve(bundle) : loadBundle(bookingId, by), companionOf(bookingId)]);
  if (!b.bs.template) return null;
  if (cur && cur.status !== 'open') return cur.id;
  const bytes = await renderBlindSpot(b, { title: `Blind Spot rental agreement ${b.f.booking.booking_number}` });
  if (!bytes) return null;
  const sha = await sha256Hex(bytes);
  if (cur && cur.document_sha256 === sha && cur.template_id === b.bs.template.id) return cur.id;
  const key = `bookings/${bookingId}/blindspot-${sha.slice(0, 16)}.pdf`;
  await (await storage()).put('agreements', key, bytes, 'application/pdf');
  return (await rpc('server_open_agreement_companion', { p_booking: bookingId, p_by: by, p_template: b.bs.template.id, p_storage_path: key, p_sha256: sha }, SR)) as unknown as string | null;
}

/** Never in the way of the rental agreement: a second agreement that cannot be made now is made on the next opening. */
export async function openCompanionQuietly(bookingId: string, by: string, bundle?: Bundle): Promise<void> {
  try { await openCompanion(bookingId, by, bundle); } catch (e) { console.error('blindspot agreement', bookingId, e instanceof Error ? e.message : e); }
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
  const b = await loadBundle(bookingId, by);
  const { certificateSigners } = await import('@/server/portal/agreement');
  const signers = await certificateSigners(bookingId);
  const renterCert = signers.find((x) => x.signer_role === 'renter');
  // each additional driver's drawn signature (box 10), from their signing session
  const drivers: Signature[] = [];
  for (const d of signers.filter((x) => x.signer_role === 'additional_driver')) {
    const path = (d as { signature_path?: string | null }).signature_path;
    if (path && d.signature_method === 'drawn') { const png = await s.get('agreements', path).catch(() => null); if (png) drivers.push({ png }); }
  }
  const ini = await initialsOf(b, renterCert);
  const lines: Array<[string, string]> = [
    ['Document', `Blind Spot Car Rental agreement, filled for this booking (template ${b.bs.template?.version ?? ''})`],
    ['Signed with', `the same signature as CarmaCars rental agreement ${c.agreement_number}`],
    ['Unsigned document SHA-256', c.document_sha256],
    ...(r ? [[`Renter: ${r.signer_name}`, `${when(r.signed_at)}; method ${r.method}${r.ip_address ? `; IP address ${r.ip_address}` : ''}${r.user_agent ? `; device ${r.user_agent}` : ''}`] as [string, string]] : []),
    ['Signed in boxes', `16 (Loss Damage Waiver), 17 (tickets, violations and tolls) and 20 (the terms of pages 1 and 2)${drivers.length ? '; the additional drivers in box 10' : ''}${ini.images.get('fees') ? '; initials on the clean-up charge line and box 40' : ''}`],
    ['Authorized company representative', `${b.bs.rep.full_name || b.bs.rep.name}, box 21 (${b.bs.rep.signature_key ? 'signature image on file' : 'name written for the representative'})`]
  ];
  const cert: Certificate | null = signers.length ? { document: `Blind Spot rental agreement for booking ${b.f.booking.booking_number} (signed with rental agreement ${c.agreement_number})`,
    hashes: [{ label: 'Blind Spot rental agreement', sha256: c.document_sha256 }], signers, verifyUrl: verifyUrl(), at: r?.signed_at ?? new Date().toISOString() } : null;
  const out = await renderBlindSpot(b, { base: unsigned, renter, drivers, initials: ini.images.get('fees') ?? ini.images.values().next().value ?? null,
    record: { title: 'Signature record', lines }, title: `Signed Blind Spot rental agreement ${c.agreement_number}`, certificate: cert });
  const sha = await sha256Hex(out!);
  const key = `bookings/${bookingId}/blindspot-${c.agreement_number}-signed.pdf`;
  await s.put('agreements', key, out!, 'application/pdf');
  await rpc('server_attach_companion_signed', { p_companion: c.id, p_storage_path: key, p_sha256: sha }, SR);
}
