// The certificate of completion (migration 0154): the last pages of every signed rental agreement, Blind Spot form,
// amendment and new version. For each signer: who they are, how they proved it (the one-time code and where it went,
// the licence on file), what they were shown (each document's SHA-256 before signing), each step with its time, IP
// address and device (viewed, each initial, each consent, the signature), the place when they allowed it, and how they
// signed (remotely, or in person with the staff member who collected it). The file's own SHA-256 is recorded when it is
// stored: anyone can check a copy on /verify (tamper-evident: a changed byte gives another SHA-256).
// pdf-lib only (works in the Worker and in Node). Relative imports with their extension: the unit tests run it directly.
import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from 'pdf-lib';

export interface CertEvent { at: string; kind: string; detail?: Record<string, unknown> | null; ip_address?: string | null; user_agent?: string | null }
export interface CertSigner {
  signer_name: string; signer_role: string; method: 'remote' | 'in_person' | string; collected_by?: string | null;
  documents?: Array<{ title: string; sha256: string }> | null;
  otp_channel?: string | null; otp_to?: string | null; otp_verified_at?: string | null; viewed_at?: string | null;
  initials?: Record<string, { at: string; typed?: string | null }> | null; consents?: Record<string, { at: string; text?: string | null }> | null;
  geo?: { lat: number; lng: number; accuracy_m?: number | null; at?: string } | null;
  ip_address?: string | null; user_agent?: string | null; signature_method?: string | null; typed_fallback?: boolean | null; signed_at?: string | null;
  licence?: { licence_front?: string | null; licence_back?: string | null; selfie?: string | null; verified?: boolean; expiry?: string | null } | null;
  events?: CertEvent[] | null;
}
export interface Certificate {
  /** "Rental agreement RA-20001 for booking CC-10001" */
  document: string;
  /** each document signed and its SHA-256 before signing */
  hashes: Array<{ label: string; sha256: string }>;
  signers: CertSigner[];
  /** CarmaCars' countersignature or the staff member's, when there is one */
  countersign?: { name: string; at: string | null; text: string } | null;
  verifyUrl: string;
  /** when the certificate was made (deterministic renders pass a fixed time) */
  at: string;
}

const TZ = 'America/Toronto';
export function stamp(iso: string | null | undefined): string {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false })
    .formatToParts(d).map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day} ${p.hour === '24' ? '00' : p.hour}:${p.minute}:${p.second} Toronto`;
}
const STEP: Record<string, string> = { started: 'Signing opened', code_sent: 'Identity code sent', code_failed: 'Wrong code entered', code_verified: 'Identity code confirmed',
  viewed: 'Documents viewed', document_opened: 'PDF opened', initial: 'Initialled', consent: 'Consented', geolocation: 'Location shared', signature: 'Signature drawn', signed: 'Signed' };
const CLAUSE: Record<string, string> = { damage: 'damage and the deductible', charges: 'the deposit and later charges', fees: 'fuel, kilometres and late returns', coverage: 'the coverage choice', cancellation: 'cancellation' };
const CONSENT: Record<string, string> = { esign: 'to sign electronically', erecords: 'to receive records electronically', card: 'to card charges under the agreement' };

const safe = (s: string) => s.replace(/[^\x20-\x7E\xA0-\xFF]/g, (c) => ({ '’': "'", '‘': "'", '“': '"', '”': '"', '–': '-', '—': '-' } as Record<string, string>)[c] ?? '');

export function eventLine(e: CertEvent): string {
  const d = e.detail ?? {};
  const what = e.kind === 'initial' ? `${STEP.initial} ${CLAUSE[String(d.code)] ?? d.code}`
    : e.kind === 'consent' ? `${STEP.consent} ${CONSENT[String(d.code)] ?? d.code}`
    : e.kind === 'code_sent' || e.kind === 'code_verified' ? `${STEP[e.kind]} (${d.channel === 'sms' ? 'text' : 'email'} to ${d.to ?? ''})`
    : e.kind === 'started' ? `${STEP.started}${d.method === 'in_person' ? ` on a CarmaCars device${d.collected_by ? `, collected by ${d.collected_by}` : ''}` : ' remotely'}`
    : e.kind === 'geolocation' ? STEP.geolocation
    : STEP[e.kind] ?? e.kind;
  return `${stamp(e.at)}  ${what}${e.ip_address ? `  IP ${e.ip_address}` : ''}`;
}

/** The certificate's lines, for the PDF and for the tests. */
export function certificateLines(c: Certificate): Array<{ text: string; bold?: boolean; size?: number; gap?: number }> {
  const out: Array<{ text: string; bold?: boolean; size?: number; gap?: number }> = [];
  out.push({ text: 'Certificate of completion', bold: true, size: 15, gap: 6 });
  out.push({ text: c.document, size: 10 });
  out.push({ text: `Made ${stamp(c.at)}. Signed electronically under Ontario's Electronic Commerce Act, 2000.`, size: 8.5, gap: 8 });
  out.push({ text: 'What was signed (SHA-256 of each document before signing)', bold: true, size: 9.5 });
  for (const h of c.hashes) out.push({ text: `${h.label}: ${h.sha256}`, size: 8 });
  out.push({ text: '', gap: 4 });
  for (const s of c.signers) {
    out.push({ text: `${s.signer_name} (${s.signer_role.replace(/_/g, ' ')})`, bold: true, size: 10.5, gap: 2 });
    out.push({ text: `Signed: ${stamp(s.signed_at)}, ${s.method === 'in_person' ? `in person on a CarmaCars device${s.collected_by ? `, collected by ${s.collected_by}` : ''}` : 'remotely, on their own device'}; ${s.signature_method === 'typed' ? 'typed name (the accessibility fallback an Admin allowed)' : 'drawn signature'}`, size: 8.5 });
    out.push({ text: `Identity: one-time code by ${s.otp_channel === 'sms' ? 'text' : s.otp_channel === 'email' ? 'email' : '(none)'}${s.otp_to ? ` to ${s.otp_to}` : ''}, confirmed ${stamp(s.otp_verified_at)}`, size: 8.5 });
    if (s.licence) {
      const files = [s.licence.licence_front && 'front', s.licence.licence_back && 'back', s.licence.selfie && 'selfie'].filter(Boolean).join(', ');
      out.push({ text: `Licence on file: ${files || 'no images'}${s.licence.verified ? '; identity verified by CarmaCars' : '; identity not yet verified'}${s.licence.expiry ? `; expires ${s.licence.expiry}` : ''}`, size: 8.5 });
    }
    out.push({ text: `Viewed the documents: ${stamp(s.viewed_at)}`, size: 8.5 });
    const ini = Object.entries(s.initials ?? {});
    if (ini.length) out.push({ text: `Initialled: ${ini.map(([k, v]) => `${CLAUSE[k] ?? k} (${stamp(v.at)})`).join('; ')}`, size: 8.5 });
    const con = Object.entries(s.consents ?? {});
    if (con.length) out.push({ text: `Consented: ${con.map(([k, v]) => `${CONSENT[k] ?? k} (${stamp(v.at)})`).join('; ')}`, size: 8.5 });
    if (s.geo) out.push({ text: `Place (shared by the signer): ${Number(s.geo.lat).toFixed(4)}, ${Number(s.geo.lng).toFixed(4)}${s.geo.accuracy_m ? `, within ${Math.round(Number(s.geo.accuracy_m))} m` : ''}`, size: 8.5 });
    out.push({ text: `IP address: ${s.ip_address ?? 'not recorded'}; device: ${s.user_agent ?? 'not recorded'}`, size: 8.5 });
    if (s.events?.length) {
      out.push({ text: 'Audit trail', bold: true, size: 8.5 });
      for (const e of s.events) out.push({ text: eventLine(e), size: 7.5 });
    }
    out.push({ text: '', gap: 4 });
  }
  if (c.countersign) out.push({ text: `Countersigned for CarmaCars: ${c.countersign.name}${c.countersign.at ? `, ${stamp(c.countersign.at)}` : ''}. ${c.countersign.text}`, size: 8.5, gap: 6 });
  out.push({ text: 'Tamper evidence', bold: true, size: 9.5 });
  out.push({ text: `CarmaCars records the SHA-256 of this signed file when it is stored. Anyone holding a copy can check it at ${c.verifyUrl}: a copy changed in any way, even by one character, gives a different SHA-256 and is not found.`, size: 8.5 });
  return out;
}

function wrap(font: PDFFont, text: string, size: number, width: number): string[] {
  const words = safe(text).split(/\s+/).filter(Boolean);
  const lines: string[] = []; let cur = '';
  for (const w of words) {
    const next = cur ? `${cur} ${w}` : w;
    if (font.widthOfTextAtSize(next, size) <= width) { cur = next; continue; }
    if (cur) lines.push(cur);
    if (font.widthOfTextAtSize(w, size) > width) { // a hash or a long device string: broken
      let rest = w;
      while (rest) { let n = rest.length; while (n > 1 && font.widthOfTextAtSize(rest.slice(0, n), size) > width) n--; lines.push(rest.slice(0, n)); rest = rest.slice(n); }
      cur = '';
    } else cur = w;
  }
  if (cur) lines.push(cur);
  return lines.length ? lines : [''];
}

/** The signed PDF with the certificate's pages added at the end (the page size of its last page). */
export async function appendCertificate(bytes: Uint8Array, c: Certificate): Promise<Uint8Array> {
  const doc = await PDFDocument.load(bytes, { updateMetadata: false });
  const last = doc.getPage(doc.getPageCount() - 1);
  const { width: W, height: H } = last.getSize();
  const reg = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);
  const M = 48;
  let page: PDFPage = doc.addPage([W, H]);
  let y = H - M;
  const pages: PDFPage[] = [page];
  for (const l of certificateLines(c)) {
    const size = l.size ?? 9;
    const font = l.bold ? bold : reg;
    for (const t of wrap(font, l.text, size, W - 2 * M)) {
      if (y - size * 1.35 < M + 16) { page = doc.addPage([W, H]); pages.push(page); y = H - M; }
      y -= size * 1.35;
      if (t) page.drawText(t, { x: M, y, size, font, color: rgb(0.05, 0.05, 0.1) });
    }
    y -= l.gap ?? 0;
  }
  pages.forEach((p, i) => p.drawText(safe(`Certificate of completion, page ${i + 1} of ${pages.length}. ${c.document}`), { x: M, y: 24, size: 7, font: reg, color: rgb(0.4, 0.4, 0.4) }));
  return doc.save({ useObjectStreams: true });
}

export interface SignatureLine { party: string; name: string; when: string; how: string; png?: Uint8Array | null }
/** A page of signatures added to a document already rendered (a version signed after it was made): each signer, the
 *  drawn signature, when and how. The certificate follows it. */
export async function appendSignaturePage(bytes: Uint8Array, title: string, lead: string, rows: SignatureLine[]): Promise<Uint8Array> {
  const doc = await PDFDocument.load(bytes, { updateMetadata: false });
  const last = doc.getPage(doc.getPageCount() - 1);
  const { width: W, height: H } = last.getSize();
  const reg = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);
  const M = 48;
  const page = doc.addPage([W, H]);
  let y = H - M - 16;
  page.drawText(safe(title), { x: M, y, size: 14, font: bold });
  y -= 18;
  for (const t of wrap(reg, lead, 9, W - 2 * M)) { page.drawText(t, { x: M, y, size: 9, font: reg }); y -= 12; }
  y -= 8;
  for (const r of rows) {
    page.drawText(safe(`${r.party}: ${r.name}`), { x: M, y, size: 10, font: bold });
    y -= 6;
    if (r.png) {
      try {
        const img = await doc.embedPng(r.png);
        const sc = Math.min(200 / img.width, 44 / img.height);
        page.drawImage(img, { x: M, y: y - img.height * sc, width: img.width * sc, height: img.height * sc });
        y -= img.height * sc + 4;
      } catch { /* not a PNG: the line below says how they signed */ }
    }
    page.drawLine({ start: { x: M, y }, end: { x: M + 220, y }, thickness: 0.5, color: rgb(0.3, 0.3, 0.3) });
    y -= 12;
    for (const t of wrap(reg, `${r.how}. ${r.when}`, 8.5, W - 2 * M)) { page.drawText(t, { x: M, y, size: 8.5, font: reg }); y -= 11; }
    y -= 14;
    if (y < M + 80) break;
  }
  return doc.save({ useObjectStreams: true });
}
