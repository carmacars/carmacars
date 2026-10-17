import 'server-only';
import { rpc } from '@/lib/db/repo';
import { storage } from '@/integrations/storage';
import { payments } from '@/integrations/payments';
import { agreementPdf } from '@/features/agreement/pdf';
import { when, type SignatureRow } from '@/features/agreement/model';
import { AMENDMENT_TEMPLATE_VERSION, amendmentBlocks, amendmentFooter, amendmentNumber, type ChangeFacts } from '@/features/agreement/amendment';
import { sha256Hex } from '@/server/links';

// A change to a confirmed booking, accepted by the renter (migration 0040): the amendment is rendered (pdf-lib, the
// CarmaCars header), stored in the private agreements bucket and opened for signature with its SHA-256; after the
// renter signs, any extra amount is charged to the card on file (an off-session PaymentIntent, one per change), the
// database applies the change, and the signed copy (signature image and record) is attached.
const SR = { role: 'service_role' as const };

export async function changeFacts(requestId: string, by: string): Promise<ChangeFacts> {
  return (await rpc('server_change_facts', { p_request: requestId, p_by: by }, SR)) as unknown as ChangeFacts;
}

async function logoFor(f: ChangeFacts): Promise<Uint8Array | null> {
  const k = f.company.logo_key;
  return k && /\.(png|jpe?g)$/i.test(k) ? (await storage()).get('vehicle-public', k).catch(() => null) : null;
}

/** The unsigned amendment: the same facts give the same bytes (its creation time is the change's). */
export async function renderAmendment(f: ChangeFacts, extra: { signatures?: SignatureRow[]; images?: Map<number, Uint8Array>; record?: { heading: string; lines: string[][] } } = {}): Promise<Uint8Array> {
  return agreementPdf(amendmentBlocks(f, extra.signatures), {
    title: `${extra.record ? 'Signed booking amendment' : 'Booking amendment'} ${amendmentNumber(f)}`, createdAt: new Date(f.change.created_at),
    brand: true, logo: await logoFor(f), footer: amendmentFooter(f), images: extra.images, record: extra.record
  });
}

/** Renders, stores and opens the amendment; the same document returns the amendment already open. */
export async function openAmendment(f: ChangeFacts, by: string): Promise<{ id: string; sha: string; number: string }> {
  const pdf = await renderAmendment(f);
  const sha = await sha256Hex(pdf);
  const key = `bookings/${f.booking.id}/amendments/${amendmentNumber(f)}-${sha.slice(0, 16)}.pdf`;
  await (await storage()).put('agreements', key, pdf, 'application/pdf');
  const a = (await rpc('server_open_amendment', { p_request: f.change.id, p_by: by, p_sha256: sha, p_storage_path: key, p_template_version: AMENDMENT_TEMPLATE_VERSION }, SR)) as unknown as { id: string; amendment_number: string };
  return { id: a.id, sha, number: a.amendment_number };
}

interface AmendmentRecord {
  amendment: { id: string; amendment_number: string; status: string; signed_document_id: string | null };
  record: { signer_name: string; method: string; signed_at: string; ip_address: string | null; user_agent: string | null; provider_signature: string | null; typed_name: string | null; consent_text: string; document_sha256: string } | null;
  /** CarmaCars' automatic countersignature (0051); none on an amendment signed before it. */
  countersign?: { signer_name: string; signer_title: string | null; method: string; signed_at: string; consent_text: string; staff_attribution?: string | null } | null;
}

/** After the change is applied: the signed copy, with the signature and its record, stored once. */
export async function attachSignedAmendment(amendmentId: string, requestId: string, by: string): Promise<void> {
  const r = (await rpc('server_amendment_record', { p_amendment: amendmentId }, SR)) as unknown as AmendmentRecord | null;
  if (!r || r.amendment.status !== 'signed' || r.amendment.signed_document_id || !r.record) return;
  const f = await changeFacts(requestId, by);
  const s = await storage();
  const images = new Map<number, Uint8Array>();
  if (r.record.method === 'drawn' && r.record.provider_signature) {
    const png = await s.get('agreements', r.record.provider_signature).catch(() => null);
    if (png) images.set(0, png);
  }
  const signatures: SignatureRow[] = [
    { party: 'Renter', name: r.record.signer_name, signature: r.record.method === 'typed' ? `Typed: ${r.record.typed_name ?? r.record.signer_name}` : 'Drawn signature', when: when(r.record.signed_at) },
    r.countersign
      ? { party: 'CarmaCars', name: r.countersign.signer_name, signature: r.countersign.consent_text || 'Signed electronically for CarmaCars', when: when(r.countersign.signed_at) }
      : { party: 'CarmaCars', name: f.company.brand, signature: 'Proposed or approved by CarmaCars staff', when: when(f.change.created_at) }
  ];
  const pdf = await renderAmendment(f, { signatures, images, record: { heading: 'Signature record', lines: [
    ['Amendment', `${r.amendment.amendment_number}, text version ${AMENDMENT_TEMPLATE_VERSION}`],
    ['Unsigned document SHA-256', r.record.document_sha256],
    ['Statement agreed', r.record.consent_text],
    [`Renter: ${r.record.signer_name}`, `${when(r.record.signed_at)}; method ${r.record.method}${r.record.ip_address ? `; IP address ${r.record.ip_address}` : ''}${r.record.user_agent ? `; device ${r.record.user_agent}` : ''}`],
    ...(r.countersign ? [[`CarmaCars: ${r.countersign.signer_name}${r.countersign.signer_title ? `, ${r.countersign.signer_title}` : ''}`, `${when(r.countersign.signed_at)}; method ${r.countersign.method}; ${r.countersign.consent_text}`]] : []),
    ...(r.countersign?.staff_attribution ? [[r.countersign.staff_attribution.split(':')[0]!, r.countersign.staff_attribution.split(':').slice(1).join(':').trim()]] : [])
  ] } });
  const sha = await sha256Hex(pdf);
  const key = `bookings/${f.booking.id}/amendments/${r.amendment.amendment_number}-signed.pdf`;
  await s.put('agreements', key, pdf, 'application/pdf');
  await rpc('server_attach_signed_amendment', { p_amendment: amendmentId, p_storage_path: key, p_sha256: sha }, SR);
}

export type PayResult = { ok: true; applied: true } | { ok: false; message: string };

/** The money and the change: an extra amount is charged to the card on file first (the same key every time, so a
 *  retry never charges twice), then the database applies the change at exactly that amount. */
export async function payAndApply(f: ChangeFacts, by: string): Promise<PayResult> {
  const diff = f.change.total_difference_cents ?? 0;
  if (diff > 0) {
    const c = f.card_on_file;
    if (!c?.method_id || !c.customer_id) return { ok: false, message: 'There is no card on file for this booking. Call us to pay the difference.' };
    const i = await (await payments()).chargeOffSession({ customerId: c.customer_id, paymentMethodId: c.method_id, amountCents: diff,
      description: `Change to booking ${f.booking.booking_number}`, metadata: { booking_id: f.booking.id, change_request_id: f.change.id, purpose: 'booking_change' },
      idempotencyKey: `booking-change:${f.change.id}` });
    if (i.status !== 'succeeded') return { ok: false, message: i.lastError ?? 'The card was declined. Nothing was charged and your booking is as it was. Try again, or call us.' };
    await rpc('server_apply_booking_change', { p_request: f.change.id, p_by: by, p_processor: { processor: 'stripe', payment_id: i.id, charge_id: i.chargeId, customer_id: i.customerId, method_id: i.paymentMethodId }, p_amount_cents: i.amountCents }, SR);
  } else {
    await rpc('server_apply_booking_change', { p_request: f.change.id, p_by: by }, SR);
  }
  return { ok: true, applied: true };
}
