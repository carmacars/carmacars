// Official fillable PDFs (migration 0042), filled in the browser (never in the Worker) and in Node for the unit tests:
// read the fields of an uploaded form, and fill one with the values the database resolved for a car and its owner.
// The official ServiceOntario forms are kept exactly as published (the owner's rule of October 23, 2026): only their
// empty text boxes are filled, as an incremental update after the publisher's last byte (pdf-update.ts). Checkboxes,
// drop-downs and signature boxes are left for the person at the counter, and the forms are signed in ink.
// Relative imports with their extension: the unit tests run this file in Node directly.
import { fillTextFields, readPdfFields, type FieldKind } from './pdf-update.ts';

export type FieldType = FieldKind;
export interface PdfField { name: string; type: FieldType; options?: string[]; page?: number; rect?: [number, number, number, number]; label?: string; tooltip?: string; max_length?: number }
/** box: the 0046 coordinates of a field of a laid-out copy (kind 'overlay'); such a copy is no longer filled. */
export interface Spec { source?: string; type?: 'text' | 'checkbox' | 'signature' | 'dropdown' | 'radio'; transform?: string; when?: string; required?: boolean;
  box?: { page: number; rect: [number, number, number, number] } }

const u8 = (b: Uint8Array | ArrayBuffer) => (b instanceof Uint8Array ? b : new Uint8Array(b));

/** The fields of a PDF, in the order the form lists them, with the page each one is on. A form that is only Adobe XFA
 *  (no PDF fields) lists the fields its XFA data keeps, named form1[0].page1[0]... as Acrobat names them. */
export async function readFields(bytes: Uint8Array | ArrayBuffer): Promise<{ fields: PdfField[]; pages: number; xfaOnly: boolean }> {
  const r = await readPdfFields(u8(bytes));
  return { pages: r.pages, xfaOnly: r.xfaOnly, fields: r.fields.map((f) => ({ name: f.name, type: f.type, ...(f.options ? { options: f.options } : {}), ...(f.page ? { page: f.page } : {}),
    ...(f.rect ? { rect: f.rect } : {}), ...(f.tooltip ? { tooltip: f.tooltip } : {}), ...(f.max_length ? { max_length: f.max_length } : {}) })) };
}

export interface Filled { bytes: Uint8Array; filled: string[]; missing: string[]; truncated: string[]; byHand: string[]; xfaOnly: boolean }
/** Fill a form's text fields with the values (app.fill_government_form). What the mapping marks as a checkbox, a
 *  drop-down, a radio button or a signature is never set: it is listed in byHand, for the person at the counter. */
export async function fillPdf(bytes: Uint8Array | ArrayBuffer, values: Record<string, string | null>, map: Record<string, Spec | string>): Promise<Filled> {
  const text: Record<string, string | null> = {}; const byHand: string[] = [];
  for (const [name, v] of Object.entries(values)) {
    const s = map[name]; const t = typeof s === 'string' ? 'text' : s?.type ?? 'text';
    if (t === 'text') text[name] = v;
    else if (t === 'signature' || (v && v !== 'Off')) byHand.push(name);
  }
  const out = await fillTextFields(u8(bytes), text);
  return { bytes: out.bytes, filled: out.filled, missing: out.missing, truncated: out.truncated, byHand: [...byHand, ...out.skipped], xfaOnly: out.xfaOnly };
}

/** A small fillable form, for the tests and the Admin's trial: a few text fields, a checkbox and a signature box. */
export async function sampleForm(): Promise<Uint8Array> {
  const { PDFDocument } = await import('pdf-lib');
  const doc = await PDFDocument.create();
  const page = doc.addPage([612, 792]);
  const form = doc.getForm();
  const font = await doc.embedFont('Helvetica');
  const rows: Array<[string, string]> = [['owner_name', 'Owner name'], ['vin', 'Vehicle identification number'], ['plate', 'Plate'], ['postal_code', 'Postal code']];
  rows.forEach(([n, label], i) => {
    page.drawText(label, { x: 50, y: 720 - i * 50, size: 10, font });
    const t = form.createTextField(n); t.addToPage(page, { x: 220, y: 712 - i * 50, width: 300, height: 22 });
  });
  page.drawText('Leased vehicle', { x: 50, y: 520, size: 10, font });
  form.createCheckBox('is_lease').addToPage(page, { x: 220, y: 514, width: 16, height: 16 });
  page.drawText('Signature', { x: 50, y: 460, size: 10, font });
  form.createTextField('owner_signature').addToPage(page, { x: 220, y: 440, width: 240, height: 40 });
  return doc.save();
}
