import 'server-only';
import { companySignature } from '@/server/signature-lines';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { storage } from '@/integrations/storage';
import { agreementBlocks, AGREEMENT_TEMPLATE_VERSION, when, type AgreementFacts, type SignatureRow } from '@/features/agreement/model';
import { sha256Hex } from '@/server/links';
import { loadBundle, privacyUrl, renderCarmaCars, verifyUrl, initialsOf, type Bundle } from '@/server/agreements/bundle';
import type { Certificate, CertSigner } from '@/features/signing/certificate';

// Built-in signing (0019 section 4): the server renders the agreement for the approved offer, stores
// the PDF in the private agreements bucket and opens it with its SHA-256; after confirmation it renders
// the signed copy (signature images, the initials, the signature record and the certificate of completion, 0143).
// 0143: both documents print everything the booking holds (server/agreements/bundle.ts); an agreement opened while
// the check-out readings are in (signed at pickup) prints them, and the database keeps what it printed.
const SR = { role: 'service_role' as const };

export { privacyUrl };

export async function agreementFacts(bookingId: string, by: string): Promise<AgreementFacts> {
  return (await rpc('server_agreement_facts', { p_booking: bookingId, p_by: by }, SR)) as unknown as AgreementFacts;
}

/** The agreement's blocks for the screen and the PDF. With the bundle, the same as the PDF prints. */
export function blocksFor(f: AgreementFacts, signatures?: SignatureRow[], b?: Bundle | null) {
  return agreementBlocks(f, { privacyUrl: privacyUrl(), signatures, extra: b?.x ?? null, insurer: b?.bs.insurer ?? null, multiDayRateCents: b?.x.multi_day_rate_cents ?? b?.bs.multi_day_rate_cents ?? null });
}

/** The unsigned document: without the agreement number, which the opening assigns. */
export function unsignedFacts(f: AgreementFacts): AgreementFacts {
  return { ...f, booking: { ...f.booking, agreement_number: null } };
}
export const unsignedBundle = (b: Bundle): Bundle => ({ ...b, f: unsignedFacts(b.f) });

/** What the signing screens show: the unsigned agreement, exactly as its PDF. */
export async function screenBlocks(bookingId: string, by: string) {
  const b = unsignedBundle(await loadBundle(bookingId, by));
  return blocksFor(b.f, undefined, b);
}

export async function renderUnsigned(raw: Bundle): Promise<Uint8Array> {
  const b = unsignedBundle(raw);
  return renderCarmaCars(b, { title: `Rental agreement ${b.f.booking.booking_number}`, createdAt: new Date(b.f.booking.offer_approved_at ?? b.f.booking.booked_at ?? 0) });
}

/** Renders, stores and opens the agreement for the approved offer. The same document returns the open agreement.
 *  The agreement number is assigned by the opening itself, so the unsigned document carries the booking number
 *  and the signed copy carries both. */
export async function openAgreement(bookingId: string, by: string): Promise<string> {
  const b = await loadBundle(bookingId, by);
  const pdf = await renderUnsigned(b);
  const sha = await sha256Hex(pdf);
  const key = `bookings/${bookingId}/agreement-v${b.f.booking.offer_approved_version ?? 'owner'}-${sha.slice(0, 16)}.pdf`;
  await (await storage()).put('agreements', key, pdf, 'application/pdf');
  const id = (await rpc('renter_open_agreement', { p_booking: bookingId, p_by: by, p_template_version: AGREEMENT_TEMPLATE_VERSION, p_document_sha256: sha, p_storage_path: key }, SR)) as unknown as string;
  // what the document printed of the check-out (an agreement signed at pickup after the readings): the database
  // compares it with the completed check-out, so no separate pickup copy is made when they match
  const p = b.x.pickup;
  await rpc('server_agreement_rendered', { p_booking: bookingId, p_pickup: (p ? { report_id: p.report_id, odometer_km: p.odometer_km, fuel_pct: p.fuel_pct, completed: p.completed } : null) as unknown as Json }, SR).catch(() => undefined);
  // the second agreement (Blind Spot's, 0127) beside it, when its template is in use; never in the way of this one
  const { openCompanionQuietly } = await import('@/server/portal/blindspot');
  await openCompanionQuietly(bookingId, by, b);
  // each additional driver with an email address gets their own signing link (migration 0040)
  const { sendFirstDriverLinks } = await import('@/server/portal/driver-links');
  await sendFirstDriverLinks(bookingId, by).catch(() => undefined);
  return id;
}

interface SigningRecord {
  agreement_id: string; agreement_number: string; status: string; template_version: string; document_sha256: string; signature_request_id: string;
  signed_document_id: string | null; document: { bucket: string; path: string } | null;
  records: Array<{ signer_role: string; signer_name: string; method: string; signed_at: string; ip_address: string | null; user_agent: string | null; provider_signature: string | null; typed_name: string | null }>;
}

/** After confirmation: the signed copy with each signature and the signature record, attached once; then the signed
 *  copy of the second agreement (0127), when the booking has one. */
export async function attachSignedCopy(bookingId: string, renterUserId: string): Promise<void> {
  await attachAgreementSignedCopy(bookingId, renterUserId);
  const { attachCompanionSigned } = await import('@/server/portal/blindspot');
  await attachCompanionSigned(bookingId, renterUserId);
}

/** The signing sessions of the booking's live agreement (0143): the certificate of completion's signers. */
export async function certificateSigners(bookingId: string): Promise<CertSigner[]> {
  return ((await rpc('server_esign_certificate_for_booking', { p_booking: bookingId }, SR).catch(() => [])) as unknown as CertSigner[]) ?? [];
}

async function attachAgreementSignedCopy(bookingId: string, renterUserId: string): Promise<void> {
  const rec = (await rpc('server_signing_record', { p_booking: bookingId }, SR)) as unknown as SigningRecord | null;
  if (!rec || rec.status !== 'completed' || rec.signed_document_id) return;
  const b = await loadBundle(bookingId, renterUserId);
  const f = b.f;
  const s = await storage();
  const rows: SignatureRow[] = [];
  const company = await companySignature(rec.signature_request_id);
  const images = new Map<number, Uint8Array>();
  const add = async (party: string, name: string, r: SigningRecord['records'][number] | undefined) => {
    if (r?.method === 'drawn' && r.provider_signature) {
      const png = await s.get('agreements', r.provider_signature).catch(() => null);
      if (png) images.set(rows.length, png);
    }
    rows.push({ party, name, signature: r ? (r.method === 'typed' ? `Typed: ${r.typed_name ?? r.signer_name}` : r.method === 'automatic' ? (company.text ?? `Signed electronically for ${f.company.legal_name || 'CarmaCars'}.`) : 'Drawn signature') : 'Not yet accepted', when: r ? when(r.signed_at) : '' });
  };
  const renterRec = rec.records.find((r) => r.signer_role === 'renter');
  await add('Renter', renterRec?.signer_name ?? f.renter?.legal_name ?? '', renterRec);
  for (const d of f.drivers.filter((x) => x.role === 'additional')) await add('Additional Driver', d.full_name, rec.records.find((r) => r.signer_role === 'additional_driver' && r.signer_name === d.full_name));
  const cc = rec.records.find((r) => r.signer_role === 'carmacars');
  await add('CarmaCars', cc?.signer_name ?? 'CarmaCars', cc);
  // signed in person on a staff member's device (0130): the record says who collected it
  const inPerson = (await rpc('server_in_person_lines', { p_request: rec.signature_request_id }, SR).catch(() => []) as unknown as Array<{ signer_role: string; signer_name: string; line: string }>) ?? [];
  const lines: string[][] = [
    ['Agreement', `${rec.agreement_number}, text version ${rec.template_version}`],
    ['Unsigned document SHA-256', rec.document_sha256],
    ...rec.records.map((r) => { const ip = inPerson.find((x) => x.signer_role === r.signer_role && x.signer_name === r.signer_name);
      return [`${r.signer_role.replace('_', ' ')}: ${r.signer_name}`, `${r.signed_at ? when(r.signed_at) : 'signed on paper'}; method ${r.method}${r.ip_address ? `; IP address ${r.ip_address}` : ''}${ip ? `; ${ip.line}` : r.user_agent ? `; device ${r.user_agent}` : ''}`]; }),
    ...company.lines
  ];
  // 0143: the renter's initials on the key terms, and the certificate of completion
  const signers = await certificateSigners(bookingId);
  const renterCert = signers.find((x) => x.signer_role === 'renter');
  const cert: Certificate | null = signers.length ? {
    document: `Rental agreement ${rec.agreement_number} for booking ${f.booking.booking_number}`, hashes: [{ label: 'CarmaCars rental agreement', sha256: rec.document_sha256 }],
    signers, countersign: cc ? { name: cc.signer_name, at: cc.signed_at, text: company.text ?? 'Signed electronically for CarmaCars.' } : null, verifyUrl: verifyUrl(), at: cc?.signed_at ?? new Date().toISOString()
  } : null;
  const pdf = await renderCarmaCars(b, {
    title: `Signed rental agreement ${rec.agreement_number}`, createdAt: new Date(cc?.signed_at ?? Date.now()), images,
    initials: await initialsOf(b, renterCert), record: { heading: 'Signature record', lines }, certificate: cert
  });
  const sha = await sha256Hex(pdf);
  const key = `bookings/${bookingId}/agreement-${rec.agreement_number}-signed.pdf`;
  await s.put('agreements', key, pdf, 'application/pdf');
  await rpc('server_complete_signature_request', { p_request: rec.signature_request_id, p_signed_storage_path: key, p_signed_sha256: sha }, SR);
}
