import 'server-only';
import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage, type PDFImage } from 'pdf-lib';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { env } from '@/lib/env';
import { storage, type Bucket } from '@/integrations/storage';
import { sha256Hex } from '@/server/links';
import { money } from '@/lib/format';
import { drawBrandLogo } from '@/features/brand/draw-logo';
import { stamp, type CertSigner } from '@/features/signing/certificate';
import { coverLetter, reasonOf, type LetterCharge, type Variant } from '@/features/disputes/letters';
import { compressToFit, shareOf } from '@/features/disputes/compress';
import { evidenceLabel } from '@/features/fee-evidence/model';

// The dispute evidence pack (migration 0154): one PDF that proves the rental, for Stripe's dispute evidence (or to
// download): a cover with the facts a card network asks (who, what, when, the card checks, the signing trail), the signed
// agreements with their certificates of completion (every version signed), the amendments and receipts, the check-in
// and check-out reports with their readings and photos, the licence images, the payments and charges, and every message
// sent to the renter. Kept under Stripe's 4.5 MB for all evidence: photos are added while they fit, the rest listed.
// With Stripe connected the file is uploaded and staged as the dispute's evidence (not submitted): an Admin checks it
// and presses Submit to Stripe.
// r48 FE (3192): the pack is built for every extra charge: its clause and the agreement version signed (with the
// certificate), the notice sent before billing with its delivery, receipts, time- and GPS-stamped photos, the Tracker
// readings (speed series, route, the location at the return), staff notes and the renter's replies; a cover letter per
// reason (features/disputes/letters.ts); the signing proof with the ID check and selfie match; earlier trips of the same
// person or card; photos are made smaller to fit, not dropped; and the non-card packs (e-Transfer or cash, insurer billing,
// a small claims bundle), which are never staged in Stripe.
const SR = { role: 'service_role' as const };
const BUDGET = 4_300_000;

type Ev = {
  pack: { id: string; stripe_dispute_ref: string | null };
  dispute: { amount_cents: number; reason: string | null; evidence_due_at: string | null; charge_id: string | null; intent_id: string | null } | null;
  booking: { id: string; booking_number: string; agreement_number: string | null; status: string; pickup_at: string; return_at: string; handed_over_at: string | null; checked_in_at: string | null;
    vehicle: { year: number; make: string; model: string; plate: string | null; vin: string | null } | null; total_cents: number; deposit_cents: number };
  renter: { legal_name: string; email: string | null; mobile: string | null; address: string | null; postal_code: string | null; created_at: string };
  documents: Array<{ id: string; kind: string; title: string; bucket: string; path: string; sha256: string | null; created_at: string; mime: string | null }>;
  licence: Array<{ kind: string; status: string; driver: string; bucket: string; path: string; mime: string | null; uploaded_at: string }>;
  /** r48 ops (3293): each pickup identity check, the licence and the card shown against what is on file */
  pickup_identity?: Array<{ at: string; driver: string; by: string; outcome: string; mismatches: string[]; results: Record<string, string>; card_last4: string | null }>;
  reports: Array<{ kind: string; performed_at: string; completed_at: string; odometer_km: number | null; fuel_pct: number | null; keys: number | null; by: string | null; renter_signed_at: string | null; plate: string | null;
    damages: Array<{ label: string; location: string; description: string; is_new: boolean }>; photos: Array<{ shot: string; bucket: string; path: string; taken_at: string; latitude: number | null; longitude: number | null }> }>;
  payments: Array<{ purpose: string; kind: string; method: string; amount_cents: number; status: string; card_brand: string | null; card_last4: string | null; at: string; charge_id: string | null }>;
  lines: Array<{ description: string; amount_cents: number; hst_cents: number; stage: string }>;
  messages: Array<{ at: string; channel: string; code: string; status: string; to?: string; body?: string }>;
  events: Array<{ at: string; kind: string; note: string | null }>;
  signing: { rental_agreement: CertSigner[]; amendments: CertSigner[]; versions: CertSigner[] };
  trips: { previous_completed: number };
  /** 3192 */
  variant?: Variant;
  charges?: Array<{ line_item_id: string; charge_type: string; label: string; description: string | null; amount_cents: number; hst_cents: number; created_at: string;
    statement: { number: string; issued_at: string } | null; clause: string; agreement: { agreement_number: string | null; template_version: string | null; signed_at: string | null; sha256: string | null } | null;
    evidence_status: string; evidence_override: string | null; evidence: Record<string, unknown>;
    notices: Array<{ code: string; channel: string; to: string | null; status: string; queued_at: string; sent_at: string | null; provider_id: string | null }>;
    documents: Array<{ id: string; title: string; bucket: string; path: string; mime: string | null; sha256: string | null; created_at: string }>;
    attached: Array<{ kind: string; note: string | null; at: string; by: string | null }>;
    tracker: { kind: 'speed_series' | 'route'; points: Array<{ at: string; lat: number; lng: number; speed_kmh?: number | null; ignition?: boolean | null }> } | null }>;
  return_location?: { at: string; lat: number; lng: number } | null;
  /** 3320: the evidence record of every tracker event of the booking (charged or not), with its seal and the notice the renter got */
  tracker_events?: Array<{ evidence_id: string; kind: string; tier: number | null; title: string; detail: string | null; at: string; lat: number | null; lng: number | null; speed_kmh: number | null;
    source: string; device: string | null; clause: string | null; fee_code: string | null; line_item_id: string | null; sha256: string | null; sealed_at: string | null;
    readings: Array<{ at: string; lat: number; lng: number; speed_kmh?: number | null; ignition?: boolean | null }>;
    notices: Array<{ code: string; channel: string; status: string; queued_at: string; sent_at: string | null; provider_id: string | null }> }>;
  staff_notes?: Array<{ at: string; by: string | null; body: string }>;
  renter_replies?: Array<{ at: string; channel: string; subject: string | null; body: string | null }>;
  identity?: Array<{ driver: string | null; method: string | null; status: string; provider: string | null; face_match_score: number | null; verified_at: string | null; verified_by: string | null }>;
  history?: { same_person: Array<{ booking_number: string; pickup_at: string; status: string; disputed: boolean }>; same_card: Array<{ booking_number: string; pickup_at: string; card: string }> };
  offline?: Array<{ method: string; amount_cents: number; status: string; at: string; reference: string | null }> | null;
  insurer?: Array<{ invoice_number: string; claim_number: string | null; total_cents: number; balance_cents: number; status: string; sent_at: string | null }> | null;
  balance?: { charged_cents: number };
};

interface StripeCharge { brand?: string; last4?: string; funding?: string; country?: string; cvc?: string | null; line1?: string | null; postal?: string | null; three_ds?: string | null; risk?: string | null; billing_name?: string | null; network_tx?: string | null; created?: number }

async function stripe(path: string, init?: RequestInit & { form?: Record<string, string> }): Promise<Record<string, unknown>> {
  const key = env().STRIPE_SECRET_KEY;
  if (!key) throw new Error('Stripe is not connected');
  const body = init?.form ? new URLSearchParams(init.form).toString() : init?.body;
  const r = await fetch(`https://api.stripe.com/v1${path}`, { method: init?.method ?? (init?.form ? 'POST' : 'GET'), body, headers: { authorization: `Bearer ${key}`, ...(init?.form ? { 'content-type': 'application/x-www-form-urlencoded' } : {}) } });
  const j = (await r.json()) as Record<string, unknown>;
  if (!r.ok) throw new Error(String((j.error as { message?: string } | undefined)?.message ?? `Stripe ${r.status}`));
  return j;
}
const stripeOn = () => env().PAYMENTS_PROVIDER === 'stripe' && !!env().STRIPE_SECRET_KEY;

async function chargeFacts(chargeId: string | null | undefined): Promise<StripeCharge | null> {
  if (!chargeId || !stripeOn()) return null;
  try {
    const c = await stripe(`/charges/${encodeURIComponent(chargeId)}`);
    const card = ((c.payment_method_details as Record<string, unknown> | undefined)?.card ?? {}) as Record<string, unknown>;
    const checks = (card.checks ?? {}) as Record<string, string | null>;
    return { brand: card.brand as string, last4: card.last4 as string, funding: card.funding as string, country: card.country as string, cvc: checks.cvc_check, line1: checks.address_line1_check,
      postal: checks.address_postal_code_check, three_ds: ((card.three_d_secure as Record<string, string> | undefined)?.result) ?? null, risk: ((c.outcome as Record<string, string> | undefined)?.risk_level) ?? null,
      billing_name: ((c.billing_details as Record<string, string> | undefined)?.name) ?? null, network_tx: (card.network_transaction_id as string) ?? null, created: c.created as number };
  } catch (e) { console.error('dispute pack: the charge', e instanceof Error ? e.message : e); return null; }
}

class Writer {
  page!: PDFPage; y = 0; readonly M = 48; readonly W = 612; readonly H = 792;
  constructor(public doc: PDFDocument, public reg: PDFFont, public bold: PDFFont) { this.newPage(); }
  /** r32: the brand logo at the top of the first page */
  newPage() { this.page = this.doc.addPage([this.W, this.H]); this.y = this.H - this.M; if (this.doc.getPageCount() === 1) { drawBrandLogo(this.page, this.M, this.H - this.M + 10, 110); this.y -= 26; } }
  safe(s: string) { return s.replace(/[^\x20-\x7E\xA0-\xFF]/g, ''); }
  line(text: string, size = 9, bold = false, gap = 0) {
    const f = bold ? this.bold : this.reg;
    const words = this.safe(text).split(/\s+/); let cur = '';
    const out: string[] = [];
    for (const w of words) { const n = cur ? `${cur} ${w}` : w; if (f.widthOfTextAtSize(n, size) > this.W - 2 * this.M && cur) { out.push(cur); cur = w; } else cur = n; }
    if (cur) out.push(cur);
    for (const l of out.length ? out : ['']) {
      if (this.y - size * 1.4 < this.M) this.newPage();
      this.y -= size * 1.4;
      this.page.drawText(l.slice(0, 400), { x: this.M, y: this.y, size, font: f, color: rgb(0.05, 0.05, 0.1) });
    }
    this.y -= gap;
  }
  head(text: string) { this.y -= 8; this.line(text, 12, true, 4); }
}

/** 3192: the Tracker's readings drawn as a small route sketch (north up), the last reading marked. */
function drawRoute(w: Writer, pts: Array<{ lat: number; lng: number }>) {
  if (pts.length < 2) return;
  const W = 220, H = 120;
  if (w.y - H - 10 < w.M) w.newPage();
  const lats = pts.map((p) => p.lat), lngs = pts.map((p) => p.lng);
  const [a, bb, c, d] = [Math.min(...lats), Math.max(...lats), Math.min(...lngs), Math.max(...lngs)];
  const sx = (x: number) => w.M + ((x - c) / Math.max(d - c, 1e-6)) * W, sy = (y: number) => w.y - H + ((y - a) / Math.max(bb - a, 1e-6)) * H;
  w.page.drawRectangle({ x: w.M - 2, y: w.y - H - 2, width: W + 4, height: H + 4, borderWidth: 0.5, borderColor: rgb(0.6, 0.6, 0.65) });
  for (let i = 1; i < pts.length; i++) w.page.drawLine({ start: { x: sx(pts[i - 1]!.lng), y: sy(pts[i - 1]!.lat) }, end: { x: sx(pts[i]!.lng), y: sy(pts[i]!.lat) }, thickness: 0.8, color: rgb(0.1, 0.3, 0.7) });
  const last = pts[pts.length - 1]!;
  w.page.drawCircle({ x: sx(last.lng), y: sy(last.lat), size: 2.5, color: rgb(0.8, 0.1, 0.1) });
  w.y -= H + 10;
}

export async function buildDisputePack(packId: string): Promise<void> {
  const ev = (await rpc('server_dispute_evidence', { p_pack: packId }, SR)) as unknown as Ev;
  const s = await storage();
  const doc = await PDFDocument.create();
  doc.setTitle(`Dispute evidence, booking ${ev.booking.booking_number}`); doc.setProducer('CarmaCars');
  const w = new Writer(doc, await doc.embedFont(StandardFonts.Helvetica), await doc.embedFont(StandardFonts.HelveticaBold));
  const charge = await chargeFacts(ev.dispute?.charge_id);
  const b = ev.booking; const r = ev.renter;
  const contents: Record<string, unknown> = {};
  let used = 0;

  // 1. the cover
  w.line(`Dispute evidence: booking ${b.booking_number}`, 16, true, 6);
  w.line(`Prepared ${stamp(new Date().toISOString())} by CarmaCars from its own records. Each document below is the stored original; signed documents carry their certificate of completion and can be checked against their recorded SHA-256 at ${env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '')}/verify.`, 8.5, false, 6);
  w.head('The customer');
  w.line(`Name: ${r.legal_name}. Email: ${r.email ?? ''}. Mobile: ${r.mobile ?? ''}. Address: ${r.address ?? ''}. Customer since ${r.created_at.slice(0, 10)}; ${ev.trips.previous_completed} earlier completed rental(s).`);
  w.head('The service');
  w.line(`Car rental of a ${b.vehicle ? `${b.vehicle.year} ${b.vehicle.make} ${b.vehicle.model}, plate ${b.vehicle.plate ?? ''}, VIN ${b.vehicle.vin ?? ''}` : 'car'}: booked from ${stamp(b.pickup_at)} to ${stamp(b.return_at)}; handed over ${stamp(b.handed_over_at) || 'not yet'}; returned ${stamp(b.checked_in_at) || 'not yet'}. Rental agreement ${b.agreement_number ?? ''}. Booking total ${money(b.total_cents, { cents: true })}; deposit ${money(b.deposit_cents, { cents: true })}.`);
  if (ev.dispute) { w.head('The dispute'); w.line(`${money(ev.dispute.amount_cents, { cents: true })}, reason ${ev.dispute.reason ?? 'not given'}, evidence due ${stamp(ev.dispute.evidence_due_at)}. Stripe dispute ${ev.pack.stripe_dispute_ref ?? ''}, charge ${ev.dispute.charge_id ?? ''}.`); }
  if (charge) { w.head('The card (from Stripe)'); w.line(`${(charge.brand ?? '').toUpperCase()} ending ${charge.last4 ?? ''}, ${charge.funding ?? ''}, issued in ${charge.country ?? ''}. Name on the card: ${charge.billing_name ?? 'not given'}. CVC check: ${charge.cvc ?? 'not checked'}; address line 1 check: ${charge.line1 ?? 'not checked'}; postal code check: ${charge.postal ?? 'not checked'}; 3D Secure: ${charge.three_ds ?? 'not used'}; Stripe risk level: ${charge.risk ?? 'not given'}.`); contents.card = true; }
  w.head('How the customer signed');
  const signers = [...ev.signing.rental_agreement, ...ev.signing.amendments, ...ev.signing.versions];
  if (!signers.length) w.line('No electronic signing session on record (signed on paper or before 0154).');
  for (const g of signers) w.line(`${g.signer_name} (${g.signer_role.replace(/_/g, ' ')}): signed ${stamp(g.signed_at)} ${g.method === 'in_person' ? `in person, collected by ${g.collected_by ?? 'staff'}` : 'remotely'}; ${g.otp_verified_at ? `identity code by ${g.otp_channel === 'sms' ? 'text' : g.otp_channel ?? 'none'} to ${g.otp_to ?? ''} confirmed ${stamp(g.otp_verified_at)}` : 'identity not confirmed by a one-time code'}; IP ${g.ip_address ?? ''}; device ${g.user_agent ?? ''}${g.geo ? `; place ${Number(g.geo.lat).toFixed(3)}, ${Number(g.geo.lng).toFixed(3)}` : ''}; initials on ${Object.keys(g.initials ?? {}).length} key terms; consents: ${Object.keys(g.consents ?? {}).join(', ')}.`, 8.5);
  contents.signers = signers.length;
  // 3192: the identity checks, earlier trips, and the cover letter written for the reason
  const ids = ev.identity ?? [];
  if (ids.length) { w.head('Identity check'); for (const x of ids) w.line(`${x.driver ?? 'Driver'}: ${x.method ?? 'check'} ${x.status}${x.provider ? ` (${x.provider})` : ''}${x.face_match_score !== null && x.face_match_score !== undefined ? `; selfie matched the licence photo, score ${x.face_match_score}` : ''}${x.verified_at ? `; verified ${stamp(x.verified_at)}${x.verified_by ? ` by ${x.verified_by}` : ''}` : ''}.`, 8.5); }
  const hist = ev.history ?? { same_person: [], same_card: [] };
  if (hist.same_person.length || hist.same_card.length) {
    w.head('Earlier rentals by the same person or card');
    for (const x of hist.same_person) w.line(`${x.booking_number}: from ${stamp(x.pickup_at).slice(0, 16)}, ${x.status}${x.disputed ? ', disputed' : ', not disputed'}`, 8.5);
    for (const x of hist.same_card) w.line(`${x.booking_number}: the same card (${x.card}), from ${stamp(x.pickup_at).slice(0, 16)}`, 8.5);
  }
  const variant: Variant = ev.variant ?? 'card';
  const charges = ev.charges ?? [];
  const lcharges: LetterCharge[] = charges.map((c) => ({ label: c.label, amount_cents: c.amount_cents, clause: c.clause,
    evidence: Object.keys(c.evidence).filter((k) => !['booking_record', 'signed_clause'].includes(k)).map(evidenceLabel),
    notice_sent_at: c.notices.find((n) => n.sent_at)?.sent_at ?? null, notice_status: c.notices.find((n) => n.sent_at)?.status ?? null }));
  const firstSigner = signers[0];
  const letter = coverLetter({ reason: ev.dispute?.reason ?? null, variant, bookingNumber: b.booking_number, agreementNumber: b.agreement_number, renter: r.legal_name,
    car: b.vehicle ? `${b.vehicle.year} ${b.vehicle.make} ${b.vehicle.model}` : 'car', from: b.pickup_at, to: b.return_at, handedOver: b.handed_over_at, returned: b.checked_in_at,
    amountCents: ev.dispute?.amount_cents ?? ev.balance?.charged_cents ?? null, charges: lcharges, signedWithCode: signers.length > 0 && signers.every((g) => g.otp_verified_at),
    signedAt: firstSigner?.signed_at ?? null, ip: firstSigner?.ip_address ?? null, idChecked: ids.some((x) => ['verified', 'approved', 'passed'].includes(x.status)),
    faceMatch: ids.find((x) => x.face_match_score !== null && x.face_match_score !== undefined)?.face_match_score ?? null,
    previousTrips: hist.same_person.length, sameCardTrips: hist.same_card.length, avs: charge?.line1 ?? charge?.postal ?? null, cvc: charge?.cvc ?? null, threeDs: charge?.three_ds ?? null,
    refundsCents: ev.payments.filter((p) => p.kind === 'refund' && p.status === 'succeeded').reduce((n, p) => n + p.amount_cents, 0), paymentsCount: ev.payments.length });
  w.newPage(); w.head(letter.title);
  for (const p of letter.paragraphs) w.line(p, 9, false, 4);
  contents.reason = reasonOf(ev.dispute?.reason); contents.variant = variant;

  // 2. the signed documents (the originals, appended page by page)
  const merge = async (d: { bucket: string; path: string; title: string }) => {
    const bytes = await s.get(d.bucket as Bucket, d.path).catch(() => null);
    if (!bytes || used + bytes.length > BUDGET * 0.6) return false;
    try {
      const src = await PDFDocument.load(bytes, { ignoreEncryption: true });
      const pages = await doc.copyPages(src, src.getPageIndices());
      for (const p of pages) doc.addPage(p);
      used += bytes.length;
      return true;
    } catch { return false; }
  };
  const merged: string[] = [];
  for (const d of ev.documents) if (await merge(d)) merged.push(d.title);
  contents.documents = merged;
  w.newPage();
  w.head('Documents in this pack');
  for (const t of merged) w.line(`- ${t}`);
  for (const d of ev.documents.filter((x) => !merged.includes(x.title))) w.line(`- ${d.title} (kept by CarmaCars, SHA-256 ${d.sha256 ?? ''}; not included to stay under the size limit)`);

  // 3. the check-in and check-out reports, with photos while they fit
  // 3192: every photo goes in, made smaller to fit its share of what is left (never dropped while it can be read)
  const isImage = (p: string, mime?: string | null) => /\.(jpe?g|png)$/i.test(p) || /^image\/(jpeg|png)$/.test(mime ?? '');
  let imagesLeft = ev.reports.reduce((n, r) => n + r.photos.length, 0) + ev.licence.length
    + (ev.charges ?? []).reduce((n, c) => n + c.documents.filter((x) => isImage(x.path, x.mime)).length, 0);
  let shrunk = 0;
  const embed = async (bucket: string, path: string): Promise<PDFImage | null> => {
    const raw = await s.get(bucket as Bucket, path).catch(() => null);
    const target = shareOf(BUDGET - used, imagesLeft);
    imagesLeft = Math.max(imagesLeft - 1, 0);
    if (!raw || used >= BUDGET) return null;
    const fit = await compressToFit(raw, Math.min(target, BUDGET - used)).catch(() => null);
    if (!fit || used + fit.bytes.length > BUDGET) return null;
    try { const img = fit.jpeg ? await doc.embedJpg(fit.bytes) : await doc.embedPng(fit.bytes); used += fit.bytes.length; if (fit.compressed) shrunk++; return img; } catch { return null; }
  };
  let photos = 0, listed = 0;
  for (const rep of ev.reports) {
    w.newPage();
    w.head(`${rep.kind === 'pickup' ? 'Check-in (pickup)' : rep.kind === 'return' ? 'Check-out (return)' : rep.kind.replace('_', ' ')} report, ${stamp(rep.completed_at)}`);
    w.line(`Plate ${rep.plate ?? ''}; odometer ${rep.odometer_km ?? ''} km; fuel or charge ${rep.fuel_pct ?? ''}%; keys ${rep.keys ?? ''}; by ${rep.by ?? ''}; the renter signed the report ${stamp(rep.renter_signed_at) || 'no'}.`);
    for (const d of rep.damages) w.line(`${d.is_new ? 'New damage' : 'Damage noted'} ${d.label}: ${d.location}, ${d.description}`, 8.5);
    let x = w.M; let rowH = 0;
    for (const ph of rep.photos) {
      const img = await embed(ph.bucket, ph.path);
      if (!img) { listed++; continue; }
      photos++;
      const sc = Math.min(160 / img.width, 120 / img.height);
      const iw = img.width * sc, ih = img.height * sc;
      if (x + iw > w.W - w.M) { x = w.M; w.y -= rowH + 18; rowH = 0; }
      if (w.y - ih - 18 < w.M) { w.newPage(); x = w.M; rowH = 0; }
      w.page.drawImage(img, { x, y: w.y - ih, width: iw, height: ih });
      w.page.drawText(w.safe(`${ph.shot.replace(/_/g, ' ')} ${stamp(ph.taken_at).slice(0, 16)}${ph.latitude ? ` (${ph.latitude.toFixed(3)}, ${(ph.longitude ?? 0).toFixed(3)})` : ''}`), { x, y: w.y - ih - 9, size: 6.5, font: w.reg });
      x += iw + 10; rowH = Math.max(rowH, ih);
    }
    w.y -= rowH + 20;
  }
  contents.photos = photos; contents.photos_listed = listed;

  // 4. the licence images
  if (ev.licence.length) {
    w.newPage(); w.head('Driver\'s licence and selfie on file');
    let x = w.M;
    for (const l of ev.licence) {
      const img = await embed(l.bucket, l.path);
      w.line(`${l.driver}: ${l.kind.replace(/_/g, ' ')} (${l.status}), uploaded ${stamp(l.uploaded_at)}`, 8.5);
      if (img) { const sc = Math.min(240 / img.width, 160 / img.height); if (w.y - img.height * sc < w.M) w.newPage(); w.page.drawImage(img, { x, y: w.y - img.height * sc - 4, width: img.width * sc, height: img.height * sc }); w.y -= img.height * sc + 12; x = w.M; }
    }
    contents.licence = ev.licence.length;
  }
  // 4b. the identity check made at the pickup (3293): who took the car, compared with the renter on file
  const checks = ev.pickup_identity ?? [];
  if (checks.length) {
    w.head('Identity check at the pickup');
    w.line('At the pickup the licence the person was holding was photographed and compared with the licence and photo on file, and the card they showed with the card on file.', 8.5);
    for (const c of checks) {
      const said = Object.entries(c.results).filter(([, v]) => v !== 'not_checked').map(([k, v]) => `${k.replace(/_/g, ' ')}: ${v.replace(/_/g, ' ')}`).join('; ');
      w.line(`${stamp(c.at)}  ${c.driver}, checked by ${c.by}: ${c.outcome}${said ? ` (${said})` : ''}${c.card_last4 ? `. Card shown ending ${c.card_last4}` : ''}`, 8.5);
      for (const m of c.mismatches) w.line(`  ${m}`, 8);
    }
    contents.pickup_identity = checks.length;
  }

  // 4b. 3192: every extra charge with its proof
  if (charges.length) {
    w.newPage(); w.head('The charges and their proof');
    let n = 0;
    for (const c of charges) {
      n++;
      w.line(`${n}. ${c.label}: ${money(c.amount_cents, { cents: true })} plus tax ${money(c.hst_cents, { cents: true })}${c.statement ? `, statement ${c.statement.number} of ${stamp(c.statement.issued_at).slice(0, 16)}` : ''}.`, 10, true, 2);
      if (c.description) w.line(c.description, 8.5);
      w.line(`Clause: ${c.clause}, rental agreement ${c.agreement?.agreement_number ?? b.agreement_number ?? ''}${c.agreement?.template_version ? `, text version ${c.agreement.template_version}` : ''}${c.agreement?.signed_at ? `, signed ${stamp(c.agreement.signed_at)}` : ''}${c.agreement?.sha256 ? ` (SHA-256 ${c.agreement.sha256}; its certificate of completion is in this pack)` : ''}.`, 8.5);
      for (const x of c.notices) w.line(`Notice before billing: ${x.code.replace(/_/g, ' ')} by ${x.channel}${x.to ? ` to ${x.to}` : ''}, ${x.status}${x.sent_at ? ` ${stamp(x.sent_at)}` : ''}${x.provider_id ? `, provider message ${x.provider_id}` : ''}.`, 8);
      const found = Object.keys(c.evidence).filter((k) => !['booking_record'].includes(k));
      if (found.length) w.line(`Evidence on record: ${found.map(evidenceLabel).join('; ')}.`, 8);
      if (c.evidence_override) w.line(`Charged by an Admin without part of its evidence: ${c.evidence_override}`, 8);
      for (const a of c.attached) w.line(`Staff note (${a.kind.replace(/_/g, ' ')}${a.by ? `, ${a.by}` : ''}, ${stamp(a.at).slice(0, 16)}): ${a.note ?? ''}`, 8);
      if (c.tracker?.points.length) {
        const pts = c.tracker.points;
        if (c.tracker.kind === 'speed_series') for (const p of pts) w.line(`Tracker ${stamp(p.at)}: ${p.speed_kmh ?? '?'} km/h at ${p.lat.toFixed(5)}, ${p.lng.toFixed(5)}`, 7.5);
        else w.line(`Tracker route: ${pts.length} readings from ${stamp(pts[0]!.at).slice(0, 16)} to ${stamp(pts[pts.length - 1]!.at).slice(0, 16)}; last at ${pts[pts.length - 1]!.lat.toFixed(5)}, ${pts[pts.length - 1]!.lng.toFixed(5)}.`, 8);
        drawRoute(w, pts);
      }
      for (const d of c.documents) {
        if (isImage(d.path, d.mime)) {
          const img = await embed(d.bucket, d.path);
          if (img) { const sc = Math.min(260 / img.width, 180 / img.height); if (w.y - img.height * sc - 14 < w.M) w.newPage(); w.page.drawImage(img, { x: w.M, y: w.y - img.height * sc - 4, width: img.width * sc, height: img.height * sc }); w.y -= img.height * sc + 10; }
          w.line(`${d.title}${img ? '' : ' (kept by CarmaCars)'}, SHA-256 ${d.sha256 ?? ''}`, 7.5);
        } else if (await merge(d)) { merged.push(d.title); w.line(`${d.title}: appended at the end of this pack`, 7.5); }
        else w.line(`${d.title}: kept by CarmaCars, SHA-256 ${d.sha256 ?? ''}`, 7.5);
      }
      w.y -= 6;
    }
    if (ev.return_location) w.line(`The car's location at the return (Tracker): ${ev.return_location.lat.toFixed(5)}, ${ev.return_location.lng.toFixed(5)} at ${stamp(ev.return_location.at)}.`, 8.5);
    contents.charges = charges.length;
  }
  if ((ev.tracker_events ?? []).length) {
    // 3320: every tracker event of the rental, charged or not: the map point, speed, time and source, the clause, the
    // notice sent, the readings around it and the record's seal (the SHA-256 kept in the database)
    w.newPage(); w.head('Tracker events');
    w.line('Each event the Tracker recorded during the rental, from its evidence record. The renter consented to tracking and agreed that Tracker data is evidence (rental agreement sections 12.1 and 12.2).', 8.5);
    for (const [i, t] of (ev.tracker_events ?? []).entries()) {
      w.line(`${i + 1}. ${t.title}`, 10, true, 2);
      w.line(`${stamp(t.at)}${t.speed_kmh != null ? `, ${t.speed_kmh} km/h` : ''}${t.lat != null && t.lng != null ? `, at ${Number(t.lat).toFixed(5)}, ${Number(t.lng).toFixed(5)}` : ''}. Source: ${t.source.replace(/_/g, ' ')}${t.device ? `, tracker ${t.device}` : ''}.`, 8.5);
      if (t.detail) w.line(t.detail, 8.5);
      if (t.clause) w.line(`Clause: ${t.clause}.${t.line_item_id ? ' Charged: see the charge above that names this record.' : ' Not charged.'}`, 8);
      for (const x of t.notices) w.line(`Notice to the renter: ${x.code.replace(/_/g, ' ')} by ${x.channel}, ${x.status}${x.sent_at ? ` ${stamp(x.sent_at)}` : ` (queued ${stamp(x.queued_at)})`}${x.provider_id ? `, provider message ${x.provider_id}` : ''}.`, 8);
      for (const p of t.readings.slice(0, 40)) w.line(`Tracker ${stamp(p.at)}: ${p.speed_kmh ?? '?'} km/h at ${Number(p.lat).toFixed(5)}, ${Number(p.lng).toFixed(5)}`, 7.5);
      w.line(`Evidence record ${t.evidence_id}, SHA-256 ${t.sha256 ?? 'pending'}${t.sealed_at ? `, sealed ${stamp(t.sealed_at)}` : ''}.`, 7.5);
      w.y -= 6;
    }
    contents.tracker_events = (ev.tracker_events ?? []).length;
  }
  if ((ev.staff_notes ?? []).length || (ev.renter_replies ?? []).length) {
    w.newPage(); w.head('Staff notes'); for (const x of ev.staff_notes ?? []) w.line(`${stamp(x.at)} ${x.by ?? ''}: ${x.body}`, 8);
    w.head('The customer\'s replies'); for (const x of ev.renter_replies ?? []) w.line(`${stamp(x.at)} ${x.channel}${x.subject ? ` "${x.subject}"` : ''}: ${x.body ?? ''}`, 8);
  }
  if (ev.offline?.length) { w.head('Payments by e-Transfer or cash'); for (const p of ev.offline) w.line(`${stamp(p.at)} ${p.method.replace(/_/g, ' ')} ${money(p.amount_cents, { cents: true })} ${p.status}${p.reference ? `, ref. ${p.reference}` : ''}`, 8); }
  if (ev.insurer?.length) { w.head('Insurer invoices'); for (const x of ev.insurer) w.line(`${x.invoice_number}${x.claim_number ? `, claim ${x.claim_number}` : ''}: ${money(x.total_cents, { cents: true })}, balance ${money(x.balance_cents, { cents: true })}, ${x.status}${x.sent_at ? `, sent ${stamp(x.sent_at).slice(0, 16)}` : ''}`, 8); }
  contents.photos_shrunk = shrunk;

  // 5. payments and charges, 6. the messages and the booking's history
  w.newPage(); w.head('Payments');
  for (const p of ev.payments) w.line(`${stamp(p.at)}  ${p.purpose.replace(/_/g, ' ')} ${p.kind}  ${money(p.amount_cents, { cents: true })}  ${p.method}${p.card_last4 ? ` ${(p.card_brand ?? '').toUpperCase()} ending ${p.card_last4}` : ''}  ${p.status}${p.charge_id ? `  charge ${p.charge_id}` : ''}`, 8);
  w.head('Charges');
  for (const l of ev.lines) w.line(`${l.stage}: ${l.description}  ${money(l.amount_cents, { cents: true })} + HST ${money(l.hst_cents, { cents: true })}`, 8);
  w.head('Messages to the customer');
  for (const m of ev.messages) w.line(`${stamp(m.at)}  ${m.channel}  ${m.code}  ${m.status}${m.to ? `  to ${m.to}` : ''}${m.body ? `: ${m.body}` : ''}`, 7.5);
  w.head('Booking history');
  for (const e of ev.events) w.line(`${stamp(e.at)}  ${e.kind.replace(/_/g, ' ')}${e.note ? `: ${e.note}` : ''}`, 7.5);
  contents.messages = ev.messages.length;

  const bytes = await doc.save({ useObjectStreams: true });
  const sha = await sha256Hex(bytes);
  const key = `disputes/${b.id}/pack-${packId}.pdf`;
  await s.put('documents', key, bytes, 'application/pdf');
  // staged in Stripe (not submitted): the file and the text fields a reviewer reads
  let fileId: string | null = null; let stageError: string | null = null;
  if (stripeOn() && ev.pack.stripe_dispute_ref && variant === 'card') {
    try {
      const form = new FormData();
      form.set('purpose', 'dispute_evidence');
      form.set('file', new Blob([bytes as unknown as BlobPart], { type: 'application/pdf' }), `dispute-evidence-${b.booking_number}.pdf`);
      const up = await fetch('https://files.stripe.com/v1/files', { method: 'POST', body: form, headers: { authorization: `Bearer ${env().STRIPE_SECRET_KEY}` } });
      const uj = (await up.json()) as { id?: string; error?: { message?: string } };
      if (!up.ok || !uj.id) throw new Error(uj.error?.message ?? `Stripe files ${up.status}`);
      fileId = uj.id;
      const log = signers.map((g) => `${g.signer_name}: ${g.otp_verified_at ? `code confirmed ${stamp(g.otp_verified_at)} (${g.otp_channel})` : 'no one-time code (not asked)'}, signed ${stamp(g.signed_at)}, IP ${g.ip_address ?? ''}, ${g.user_agent ?? ''}`).join('\n');
      await stripe(`/disputes/${encodeURIComponent(ev.pack.stripe_dispute_ref)}`, { form: {
        'evidence[service_documentation]': fileId, 'evidence[customer_signature]': fileId, 'evidence[customer_name]': r.legal_name, 'evidence[customer_email_address]': r.email ?? '',
        'evidence[billing_address]': r.address ?? '', 'evidence[service_date]': (b.handed_over_at ?? b.pickup_at).slice(0, 10),
        'evidence[product_description]': `Car rental, ${b.vehicle ? `${b.vehicle.year} ${b.vehicle.make} ${b.vehicle.model} (plate ${b.vehicle.plate ?? ''})` : ''}, ${b.pickup_at.slice(0, 10)} to ${b.return_at.slice(0, 10)}, under signed rental agreement ${b.agreement_number ?? ''}.`,
        'evidence[access_activity_log]': log.slice(0, 20000), 'evidence[uncategorized_text]': `${signers.length && signers.every((g) => g.otp_verified_at) ? 'The customer confirmed their identity with a one-time code, initialled' : 'The customer signed electronically (no one-time code was asked; the time, IP address and device of each step are recorded), initialled'} the key terms (damage, deposit and later charges, fees, coverage, cancellation), consented to card charges under the agreement and drew their signature; the car was checked in and out with photos. The PDF holds the signed agreements with their certificates, the reports, the licence and the messages.`.slice(0, 20000),
        ...letter.stripe, submit: 'false' } });
    } catch (e) { stageError = e instanceof Error ? e.message : String(e); console.error('dispute pack: staging', stageError); }
  }
  await rpc('server_dispute_pack_built', { p_pack: packId, p: { path: key, sha256: sha, size: bytes.length, stripe_file_id: fileId, stage_error: stageError, contents } as unknown as Json }, SR);
}

/** An Admin submits the staged evidence to Stripe. */
export async function submitDisputePack(packId: string, by: string): Promise<void> {
  const k = (await rpc('server_dispute_pack', { p_pack: packId }, SR)) as unknown as { status: string; stripe_dispute_ref: string | null; stripe_file_id: string | null } | null;
  if (!k) throw new Error('Not found');
  if (k.status === 'submitted') return;
  if (!stripeOn()) throw new Error('Stripe is not connected here: download the pack and upload it in Stripe\'s dashboard.');
  if (!k.stripe_dispute_ref || !k.stripe_file_id) throw new Error('The pack is not staged in Stripe yet: build it again.');
  try {
    await stripe(`/disputes/${encodeURIComponent(k.stripe_dispute_ref)}`, { form: { submit: 'true' } });
    await rpc('server_dispute_pack_submitted', { p_pack: packId, p_by: by }, SR);
  } catch (e) {
    await rpc('server_dispute_pack_submitted', { p_pack: packId, p_by: by, p_error: e instanceof Error ? e.message : String(e) }, SR).catch(() => undefined);
    throw e;
  }
}
