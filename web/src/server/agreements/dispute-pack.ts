import 'server-only';
import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage, type PDFImage } from 'pdf-lib';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { env } from '@/lib/env';
import { storage, type Bucket } from '@/integrations/storage';
import { sha256Hex } from '@/server/links';
import { money } from '@/lib/format';
import { stamp, type CertSigner } from '@/features/signing/certificate';

// The dispute evidence pack (migration 0154): one PDF that proves the rental, for Stripe's dispute evidence (or to
// download): a cover with the facts a card network asks (who, what, when, the card checks, the signing trail), the signed
// agreements with their certificates of completion (every version signed), the amendments and receipts, the check-out
// and check-in reports with their readings and photos, the licence images, the payments and charges, and every message
// sent to the renter. Kept under Stripe's 4.5 MB for all evidence: photos are added while they fit, the rest listed.
// With Stripe connected the file is uploaded and staged as the dispute's evidence (not submitted): an Admin checks it
// and presses Submit to Stripe.
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
  reports: Array<{ kind: string; performed_at: string; completed_at: string; odometer_km: number | null; fuel_pct: number | null; keys: number | null; by: string | null; renter_signed_at: string | null; plate: string | null;
    damages: Array<{ label: string; location: string; description: string; is_new: boolean }>; photos: Array<{ shot: string; bucket: string; path: string; taken_at: string; latitude: number | null; longitude: number | null }> }>;
  payments: Array<{ purpose: string; kind: string; method: string; amount_cents: number; status: string; card_brand: string | null; card_last4: string | null; at: string; charge_id: string | null }>;
  lines: Array<{ description: string; amount_cents: number; hst_cents: number; stage: string }>;
  messages: Array<{ at: string; channel: string; code: string; status: string; to?: string; body?: string }>;
  events: Array<{ at: string; kind: string; note: string | null }>;
  signing: { rental_agreement: CertSigner[]; amendments: CertSigner[]; versions: CertSigner[] };
  trips: { previous_completed: number };
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
  newPage() { this.page = this.doc.addPage([this.W, this.H]); this.y = this.H - this.M; }
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
  for (const g of signers) w.line(`${g.signer_name} (${g.signer_role.replace(/_/g, ' ')}): signed ${stamp(g.signed_at)} ${g.method === 'in_person' ? `in person, collected by ${g.collected_by ?? 'staff'}` : 'remotely'}; identity code by ${g.otp_channel === 'sms' ? 'text' : g.otp_channel ?? 'none'} to ${g.otp_to ?? ''} confirmed ${stamp(g.otp_verified_at)}; IP ${g.ip_address ?? ''}; device ${g.user_agent ?? ''}${g.geo ? `; place ${Number(g.geo.lat).toFixed(3)}, ${Number(g.geo.lng).toFixed(3)}` : ''}; initials on ${Object.keys(g.initials ?? {}).length} key terms; consents: ${Object.keys(g.consents ?? {}).join(', ')}.`, 8.5);
  contents.signers = signers.length;

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

  // 3. the check-out and check-in reports, with photos while they fit
  const embed = async (bucket: string, path: string): Promise<PDFImage | null> => {
    const bytes = await s.get(bucket as Bucket, path).catch(() => null);
    if (!bytes || used + bytes.length > BUDGET) return null;
    try { const img = bytes[0] === 0x89 ? await doc.embedPng(bytes) : await doc.embedJpg(bytes); used += bytes.length; return img; } catch { return null; }
  };
  let photos = 0, listed = 0;
  for (const rep of ev.reports) {
    w.newPage();
    w.head(`${rep.kind === 'pickup' ? 'Check-out (pickup)' : rep.kind === 'return' ? 'Check-in (return)' : rep.kind.replace('_', ' ')} report, ${stamp(rep.completed_at)}`);
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
  if (stripeOn() && ev.pack.stripe_dispute_ref) {
    try {
      const form = new FormData();
      form.set('purpose', 'dispute_evidence');
      form.set('file', new Blob([bytes as unknown as BlobPart], { type: 'application/pdf' }), `dispute-evidence-${b.booking_number}.pdf`);
      const up = await fetch('https://files.stripe.com/v1/files', { method: 'POST', body: form, headers: { authorization: `Bearer ${env().STRIPE_SECRET_KEY}` } });
      const uj = (await up.json()) as { id?: string; error?: { message?: string } };
      if (!up.ok || !uj.id) throw new Error(uj.error?.message ?? `Stripe files ${up.status}`);
      fileId = uj.id;
      const log = signers.map((g) => `${g.signer_name}: code confirmed ${stamp(g.otp_verified_at)} (${g.otp_channel}), signed ${stamp(g.signed_at)}, IP ${g.ip_address ?? ''}, ${g.user_agent ?? ''}`).join('\n');
      await stripe(`/disputes/${encodeURIComponent(ev.pack.stripe_dispute_ref)}`, { form: {
        'evidence[service_documentation]': fileId, 'evidence[customer_signature]': fileId, 'evidence[customer_name]': r.legal_name, 'evidence[customer_email_address]': r.email ?? '',
        'evidence[billing_address]': r.address ?? '', 'evidence[service_date]': (b.handed_over_at ?? b.pickup_at).slice(0, 10),
        'evidence[product_description]': `Car rental, ${b.vehicle ? `${b.vehicle.year} ${b.vehicle.make} ${b.vehicle.model} (plate ${b.vehicle.plate ?? ''})` : ''}, ${b.pickup_at.slice(0, 10)} to ${b.return_at.slice(0, 10)}, under signed rental agreement ${b.agreement_number ?? ''}.`,
        'evidence[access_activity_log]': log.slice(0, 20000), 'evidence[uncategorized_text]': `The customer confirmed their identity with a one-time code, initialled the key terms (damage, deposit and later charges, fees, coverage, cancellation), consented to card charges under the agreement and drew their signature; the car was checked out and in with photos. The PDF holds the signed agreements with their certificates, the reports, the licence and the messages.`.slice(0, 20000),
        submit: 'false' } });
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
