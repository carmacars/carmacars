import 'server-only';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import { storage } from '@/integrations/storage';
import { agreementBlocks, AGREEMENT_TEMPLATE_VERSION, when, type AgreementFacts, type SignatureRow } from '@/features/agreement/model';
import { agreementPdf } from '@/features/agreement/pdf';
import { sha256Hex } from '@/server/links';

// Built-in signing (0019 section 4): the server renders the agreement for the approved offer, stores
// the PDF in the private agreements bucket and opens it with its SHA-256; after confirmation it renders
// the signed copy (signature images and the signature record) and attaches it.
const SR = { role: 'service_role' as const };

export const privacyUrl = () => `${env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '')}/privacy`;

export async function agreementFacts(bookingId: string, by: string): Promise<AgreementFacts> {
  return (await rpc('server_agreement_facts', { p_booking: bookingId, p_by: by }, SR)) as unknown as AgreementFacts;
}

export function blocksFor(f: AgreementFacts, signatures?: SignatureRow[]) {
  return agreementBlocks(f, { privacyUrl: privacyUrl(), signatures });
}

const footer = (f: AgreementFacts) => `CarmaCars rental agreement ${f.booking.agreement_number ?? ''} for booking ${f.booking.booking_number}. ${AGREEMENT_TEMPLATE_VERSION}`;

/** The unsigned document: without the agreement number, which the opening assigns. */
export function unsignedFacts(f: AgreementFacts): AgreementFacts {
  return { ...f, booking: { ...f.booking, agreement_number: null } };
}
export async function renderUnsigned(raw: AgreementFacts): Promise<Uint8Array> {
  const f = unsignedFacts(raw);
  return agreementPdf(blocksFor(f), { title: `Rental agreement ${f.booking.booking_number}`, createdAt: new Date(f.booking.offer_approved_at ?? f.booking.booked_at ?? 0), footer: footer(f) });
}

/** Renders, stores and opens the agreement for the approved offer. The same document returns the open agreement.
 *  The agreement number is assigned by the opening itself, so the unsigned document carries the booking number
 *  and the signed copy carries both. */
export async function openAgreement(bookingId: string, by: string): Promise<string> {
  const f = await agreementFacts(bookingId, by);
  const pdf = await renderUnsigned(f);
  const sha = await sha256Hex(pdf);
  const key = `bookings/${bookingId}/agreement-v${f.booking.offer_approved_version ?? 'owner'}-${sha.slice(0, 16)}.pdf`;
  await (await storage()).put('agreements', key, pdf, 'application/pdf');
  const id = (await rpc('renter_open_agreement', { p_booking: bookingId, p_by: by, p_template_version: AGREEMENT_TEMPLATE_VERSION, p_document_sha256: sha, p_storage_path: key }, SR)) as unknown as string;
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

/** After confirmation: the signed copy with each signature and the signature record, attached once. */
export async function attachSignedCopy(bookingId: string, renterUserId: string): Promise<void> {
  const rec = (await rpc('server_signing_record', { p_booking: bookingId }, SR)) as unknown as SigningRecord | null;
  if (!rec || rec.status !== 'completed' || rec.signed_document_id) return;
  const f = await agreementFacts(bookingId, renterUserId);
  const s = await storage();
  const rows: SignatureRow[] = [];
  const images = new Map<number, Uint8Array>();
  const add = async (party: string, name: string, r: SigningRecord['records'][number] | undefined) => {
    if (r?.method === 'drawn' && r.provider_signature) {
      const png = await s.get('agreements', r.provider_signature).catch(() => null);
      if (png) images.set(rows.length, png);
    }
    rows.push({ party, name, signature: r ? (r.method === 'typed' ? `Typed: ${r.typed_name ?? r.signer_name}` : r.method === 'automatic' ? 'Signed electronically for CarmaCars' : 'Drawn signature') : 'Not yet accepted', when: r ? when(r.signed_at) : '' });
  };
  const renterRec = rec.records.find((r) => r.signer_role === 'renter');
  await add('Renter', renterRec?.signer_name ?? f.renter?.legal_name ?? '', renterRec);
  for (const d of f.drivers.filter((x) => x.role === 'additional')) await add('Additional Driver', d.full_name, rec.records.find((r) => r.signer_role === 'additional_driver' && r.signer_name === d.full_name));
  const cc = rec.records.find((r) => r.signer_role === 'carmacars');
  await add('CarmaCars', cc?.signer_name ?? 'CarmaCars', cc);
  const lines: string[][] = [
    ['Agreement', `${rec.agreement_number}, text version ${rec.template_version}`],
    ['Unsigned document SHA-256', rec.document_sha256],
    ...rec.records.map((r) => [`${r.signer_role.replace('_', ' ')}: ${r.signer_name}`, `${when(r.signed_at)}; method ${r.method}${r.ip_address ? `; IP address ${r.ip_address}` : ''}${r.user_agent ? `; device ${r.user_agent}` : ''}`])
  ];
  const pdf = await agreementPdf(blocksFor(f, rows), {
    title: `Signed rental agreement ${rec.agreement_number}`, createdAt: new Date(cc?.signed_at ?? Date.now()), images,
    record: { heading: 'Signature record', lines }, footer: footer(f)
  });
  const sha = await sha256Hex(pdf);
  const key = `bookings/${bookingId}/agreement-${rec.agreement_number}-signed.pdf`;
  await s.put('agreements', key, pdf, 'application/pdf');
  await rpc('server_complete_signature_request', { p_request: rec.signature_request_id, p_signed_storage_path: key, p_signed_sha256: sha }, SR);
}
