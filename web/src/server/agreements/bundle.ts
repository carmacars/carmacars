import 'server-only';
import { rpc } from '@/lib/db/repo';
import { storage } from '@/integrations/storage';
import { env } from '@/lib/env';
import { agreementBlocks, AGREEMENT_TEMPLATE_VERSION, when, type AgreementFacts, type InitialRow, type SignatureRow } from '@/features/agreement/model';
import { clauses, depositText, type AgreementExtra, type VersionHeader } from '@/features/agreement/extra';
import { agreementPdf } from '@/features/agreement/pdf';
import { layout } from '@/features/blindspot/layout';
import { toBlindSpotFacts } from '@/features/blindspot/facts';
import { fillBlindSpot, type Signature } from '@/features/blindspot/fill';
import { appendCertificate, type Certificate, type CertSigner } from '@/features/signing/certificate';

// Both rental agreements of a booking from one read (migration 0154): the booking's facts (0028), what Blind Spot's form
// needs (0127) and everything else the two documents print (public.server_agreement_extra). Every render of either
// document goes through here: the agreement opened for signing, its signed copy, each version, each version's signed
// copy. The same facts give the same bytes.
const SR = { role: 'service_role' as const };

export interface BlindSpotExtra {
  mailing: { line: string | null; street: string | null; unit: string | null; city: string | null; province: string | null; postal_code: string | null };
  hst_number: string | null; fleet_number: string | null; odometer_out_km: number | null; multi_day_rate_cents: number | null;
  insurer: { name: string | null; claim_number: string | null; adjuster_name: string | null; adjuster_phone: string | null; authorized_days: number | null; authorized_daily_rate_cents: number | null } | null;
  template: { id: string; version: string; file_key: string; sha256: string } | null;
  rep: { name: string; full_name: string | null; signature_key: string | null; signature_sha256: string | null };
}
export interface Bundle { f: AgreementFacts; x: AgreementExtra; bs: BlindSpotExtra }

export const privacyUrl = () => `${env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '')}/privacy`;
export const verifyUrl = () => `${env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '')}/verify`;

export async function loadBundle(bookingId: string, by: string): Promise<Bundle> {
  const [f, x, bs] = await Promise.all([
    rpc('server_agreement_facts', { p_booking: bookingId, p_by: by }, SR) as unknown as Promise<AgreementFacts>,
    rpc('server_agreement_extra', { p_booking: bookingId, p_by: by }, SR) as unknown as Promise<AgreementExtra>,
    rpc('server_blindspot_facts', { p_booking: bookingId, p_by: by }, SR) as unknown as Promise<BlindSpotExtra>
  ]);
  return { f, x, bs };
}

/** The key terms of this booking, worded from its own values (the deductible, the deposit, the kilometres...). */
export function keyTerms(b: Bundle) {
  const f = b.f; const x = b.x;
  const COV: Record<number, string> = { 1: `OPCF 27 on my own auto policy${f.coverage?.insurer_name ? ` (${f.coverage.insurer_name}${f.coverage.policy_number ? `, policy ${f.coverage.policy_number}` : ''})` : ''}`,
    2: `the rental coverage of my credit card${f.coverage?.card_issuer ? ` (${f.coverage.card_issuer}${f.coverage.card_last4 ? ` ending ${f.coverage.card_last4}` : ''})` : ''}`,
    3: 'the CarmaCars Protection Plan', 4: 'insurance included with the car' };
  return clauses({
    deductible_cents: f.booking.deductible_cents ?? f.company.deductible_cents, deposit: depositText(x),
    card: f.card ? `${f.card.brand.toUpperCase()} ending ${f.card.last4}` : null,
    km_per_day: f.booking.km_allowance_per_day, km_total: f.booking.km_allowance_total, overage_cents_per_km: f.booking.overage_cents_per_km,
    grace_minutes: x.late.grace_minutes, late_fee_cents: x.late.fee_cents, coverage: f.booking.coverage_option ? COV[f.booking.coverage_option] ?? 'as chosen' : 'to be chosen before pickup',
    booking_type: f.booking.booking_type
  });
}

/** The initials a signer gave, as the signed copy's table rows and images. */
export async function initialsOf(b: Bundle, cert: CertSigner | null | undefined, bucket: 'agreements' = 'agreements'): Promise<{ rows: InitialRow[]; images: Map<string, Uint8Array> }> {
  const images = new Map<string, Uint8Array>();
  if (!cert?.initials) return { rows: [], images };
  const s = await storage();
  const rows: InitialRow[] = [];
  for (const c of keyTerms(b)) {
    const got = (cert.initials as Record<string, { at: string; path?: string | null; typed?: string | null }>)[c.code];
    if (!got) continue;
    if (got.path) { const png = await s.get(bucket, got.path).catch(() => null); if (png) images.set(c.code, png); }
    rows.push({ code: c.code, title: c.title, text: c.text, when: when(got.at), typed: got.typed ?? null });
  }
  return { rows, images };
}

const footer = (f: AgreementFacts, version?: VersionHeader | null) =>
  `CarmaCars rental agreement ${f.booking.agreement_number ?? ''} for booking ${f.booking.booking_number}${version ? `, version ${version.version_no}` : ''}. ${AGREEMENT_TEMPLATE_VERSION}`;

export interface CarmaCarsRender {
  version?: VersionHeader | null; signatures?: SignatureRow[]; images?: Map<number, Uint8Array>; initials?: { rows: InitialRow[]; images: Map<string, Uint8Array> } | null;
  record?: { heading: string; lines: string[][] }; title: string; createdAt: Date; certificate?: Certificate | null;
}
/** CarmaCars' agreement as a PDF. */
export async function renderCarmaCars(b: Bundle, o: CarmaCarsRender): Promise<Uint8Array> {
  const blocks = agreementBlocks(b.f, { privacyUrl: privacyUrl(), signatures: o.signatures, extra: b.x, insurer: b.bs.insurer, multiDayRateCents: b.x.multi_day_rate_cents ?? b.bs.multi_day_rate_cents,
    version: o.version ?? null, initials: o.initials?.rows ?? null });
  const pdf = await agreementPdf(blocks, { title: o.title, createdAt: o.createdAt, images: o.images, initials: o.initials?.images, record: o.record, footer: footer(b.f, o.version) });
  return o.certificate ? appendCertificate(pdf, o.certificate) : pdf;
}

/** The booking in the shape of Blind Spot's form. */
export const blindSpotFacts = (b: Bundle) => toBlindSpotFacts(b.f, b.bs, b.x);

// The template is 2.5 MB: kept in memory by its SHA-256 between renders of the same Worker; checked against the hash
// recorded when it was uploaded.
let cached: { sha: string; bytes: Uint8Array } | null = null;
export async function templateBytes(t: { file_key: string; sha256: string }): Promise<Uint8Array> {
  if (cached?.sha === t.sha256) return cached.bytes;
  const bytes = await (await storage()).get('documents', t.file_key);
  if (!bytes) throw new Error('The Blind Spot template file is missing from storage (Admin > Settings > Forms: upload it again)');
  const { sha256Hex } = await import('@/server/links');
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

export interface BlindSpotRender {
  title: string; renter?: Signature | null; drivers?: Signature[] | null; initials?: Uint8Array | null; note?: string | null;
  record?: { title: string; lines: Array<[string, string]> } | null; certificate?: Certificate | null;
  /** a signed copy is drawn on the unsigned document (its own bytes), not on the template */
  base?: Uint8Array | null;
}
export async function renderBlindSpot(b: Bundle, o: BlindSpotRender): Promise<Uint8Array | null> {
  if (!b.bs.template && !o.base) return null;
  const l = o.base ? { texts: [], dots: [], covers: [] } : layout(blindSpotFacts(b));
  const r = await fillBlindSpot(o.base ?? (await templateBytes(b.bs.template!)), l, {
    company: o.base ? null : await companySignature(b.bs.rep), renter: o.renter ?? null, drivers: o.drivers ?? null, initials: o.initials ?? null,
    record: o.record ?? null, title: o.title, note: o.note ?? null
  });
  return o.certificate ? appendCertificate(r.bytes, o.certificate) : r.bytes;
}
