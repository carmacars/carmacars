import { PDFDocument, StandardFonts, rgb } from 'pdf-lib';
import qrcode from 'qrcode-generator';

// The one-page flyer for a partner's counter (migration 0164): who sent you, the QR code of the partner's link and the short
// address, in words a renter can follow at a body shop or in a tow truck's cab. Plain Latin text only (the standard fonts).
export interface FlyerInput { business: string; code: string; link: string; kind: string; phone: string }

const ascii = (s: string) => s.normalize('NFKD').replace(/[^\x20-\x7E]/g, '');

/** The QR code of a link as rows of dark and light squares. */
export function qrMatrix(text: string): boolean[][] {
  const qr = qrcode(0, 'M');
  qr.addData(text);
  qr.make();
  const n = qr.getModuleCount();
  return Array.from({ length: n }, (_, r) => Array.from({ length: n }, (_, c) => qr.isDark(r, c)));
}

export async function flyerPdf(i: FlyerInput): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  pdf.setTitle(`CarmaCars flyer for ${ascii(i.business)}`);
  pdf.setAuthor('CarmaCars');
  const page = pdf.addPage([612, 792]);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const reg = await pdf.embedFont(StandardFonts.Helvetica);
  const ink = rgb(0.09, 0.1, 0.12);
  const grey = rgb(0.38, 0.4, 0.44);
  const W = 612;
  const centre = (t: string, y: number, size: number, f = reg, c = ink) => page.drawText(t, { x: (W - f.widthOfTextAtSize(t, size)) / 2, y, size, font: f, color: c });
  const wrap = (t: string, size: number, f: typeof reg, max: number) => {
    const out: string[] = []; let line = '';
    for (const w of t.split(/\s+/)) { const next = line ? `${line} ${w}` : w; if (f.widthOfTextAtSize(next, size) > max && line) { out.push(line); line = w; } else line = next; }
    if (line) out.push(line);
    return out;
  };
  page.drawRectangle({ x: 0, y: 700, width: W, height: 92, color: ink });
  centre('CarmaCars', 738, 34, bold, rgb(1, 1, 1));
  centre('Car rentals in Toronto and the GTA', 714, 13, reg, rgb(0.85, 0.87, 0.9));
  const heading = i.kind === 'tow_truck' ? 'Need a car after your tow?' : 'Need a car while yours is being repaired?';
  centre(heading, 650, 27, bold);
  const lines = wrap(`${ascii(i.business)} sent you. Scan the code, choose a car and send a request. A person confirms the car and the price with you before anything is charged.`, 15, reg, 440);
  lines.forEach((l, k) => centre(l, 618 - k * 21, 15, reg, grey));
  // the QR code, black on white with a quiet zone
  const m = qrMatrix(i.link);
  const size = 270; const cell = size / (m.length + 8); const x0 = (W - size) / 2; const y0 = 250;
  page.drawRectangle({ x: x0 - 6, y: y0 - 6, width: size + 12, height: size + 12, color: rgb(1, 1, 1), borderColor: ink, borderWidth: 2 });
  m.forEach((row, r) => row.forEach((dark, c) => { if (dark) page.drawRectangle({ x: x0 + (c + 4) * cell, y: y0 + size - (r + 5) * cell, width: cell + 0.2, height: cell + 0.2, color: ink }); }));
  centre(ascii(i.link.replace(/^https?:\/\//, '')), 214, 20, bold);
  centre(`Tell us the code ${i.code} if you book by phone${i.phone ? ` at ${ascii(i.phone)}` : ''}.`, 188, 13, reg, grey);
  const facts = ['Delivery to you or pickup, any time with 2 hours notice', 'Insurance replacement and accident rentals welcome', 'Your coverage options are explained before you pick up the car'];
  facts.forEach((f, k) => centre(`- ${f}`, 140 - k * 20, 13, reg, ink));
  centre('carmacars.ca', 40, 12, reg, grey);
  return pdf.save();
}
