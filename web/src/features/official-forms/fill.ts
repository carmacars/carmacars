// Official fillable PDFs (migration 0042), with pdf-lib in the browser (never in the Worker): read the fillable
// fields of an uploaded form, and fill one with the values the database resolved for a car and its owner, with
// the owner's drawn signature placed in the signature fields. Works the same in Node for the unit tests.
import { PDFCheckBox, PDFDocument, PDFDropdown, PDFOptionList, PDFRadioGroup, PDFSignature, PDFTextField, type PDFField } from 'pdf-lib';

export type FieldType = 'text' | 'checkbox' | 'dropdown' | 'radio' | 'signature' | 'button';
export interface PdfField { name: string; type: FieldType; options?: string[]; page?: number }
export interface Spec { source?: string; type?: 'text' | 'checkbox' | 'signature' | 'dropdown' | 'radio'; transform?: string; when?: string; required?: boolean }

const typeOf = (f: PDFField): FieldType =>
  f instanceof PDFTextField ? 'text' : f instanceof PDFCheckBox ? 'checkbox' : f instanceof PDFDropdown || f instanceof PDFOptionList ? 'dropdown'
    : f instanceof PDFRadioGroup ? 'radio' : f instanceof PDFSignature ? 'signature' : 'button';

/** The fillable fields of a PDF, in the order the form lists them, with the page each one is on. */
export async function readFields(bytes: Uint8Array | ArrayBuffer): Promise<{ fields: PdfField[]; pages: number }> {
  const doc = await PDFDocument.load(bytes, { ignoreEncryption: true, updateMetadata: false });
  const pages = doc.getPages();
  const fields = doc.getForm().getFields().map((f) => {
    const t = typeOf(f);
    const opts = f instanceof PDFDropdown || f instanceof PDFOptionList ? f.getOptions() : f instanceof PDFRadioGroup ? f.getOptions() : undefined;
    const w = f.acroField.getWidgets()[0];
    const ref = w?.P();
    const page = ref ? pages.findIndex((p) => p.ref === ref) + 1 : 0;
    return { name: f.getName(), type: t, ...(opts?.length ? { options: opts } : {}), ...(page > 0 ? { page } : {}) };
  });
  return { fields, pages: pages.length };
}

/** Fill a form. Values come from the database (app.fill_government_form); a signature field gets the PNG drawn on
 *  screen when one is given. flatten: the result can no longer be edited (the signed copy). */
export async function fillPdf(bytes: Uint8Array | ArrayBuffer, values: Record<string, string | null>, map: Record<string, Spec | string>, o: { signaturePng?: Uint8Array; flatten?: boolean } = {}): Promise<{ bytes: Uint8Array; filled: string[]; missing: string[] }> {
  const doc = await PDFDocument.load(bytes, { ignoreEncryption: true });
  const form = doc.getForm();
  const filled: string[] = []; const missing: string[] = [];
  const get = (name: string) => { try { return form.getField(name); } catch { return null; } };
  for (const [name, raw] of Object.entries(values)) {
    const f = get(name);
    if (!f) { missing.push(name); continue; }
    const v = raw ?? '';
    try {
      if (f instanceof PDFTextField) { const max = f.getMaxLength(); f.setText(max ? v.slice(0, max) : v); }
      else if (f instanceof PDFCheckBox) { if (/^(yes|true|on|1|x)$/i.test(v)) f.check(); else f.uncheck(); }
      else if (f instanceof PDFDropdown) { if (!v) f.clear(); else if (f.getOptions().includes(v) || f.isEditable()) f.select(v); }
      else if (f instanceof PDFOptionList) { if (v && f.getOptions().includes(v)) f.select(v); }
      else if (f instanceof PDFRadioGroup) { if (v && f.getOptions().includes(v)) f.select(v); }
      else continue;
      if (v) filled.push(name);
    } catch { missing.push(name); }
  }
  if (o.signaturePng) {
    const png = await doc.embedPng(o.signaturePng);
    const pages = doc.getPages();
    for (const [name, s] of Object.entries(map)) {
      if (typeof s === 'string' || s.type !== 'signature') continue;
      const f = get(name);
      if (!f) { missing.push(name); continue; }
      for (const w of f.acroField.getWidgets()) {
        const page = pages.find((p) => p.ref === w.P()) ?? pages[0]!;
        const r = w.getRectangle();
        const k = Math.min(r.width / png.width, r.height / png.height);
        page.drawImage(png, { x: r.x + (r.width - png.width * k) / 2, y: r.y + (r.height - png.height * k) / 2, width: png.width * k, height: png.height * k });
      }
      if (f instanceof PDFTextField) f.setText('');
      filled.push(name);
    }
  }
  if (o.flatten) { form.updateFieldAppearances(); form.flatten(); }
  return { bytes: await doc.save(), filled, missing };
}

/** A small fillable form, for the tests and the Admin's trial: a few text fields, a checkbox and a signature box. */
export async function sampleForm(): Promise<Uint8Array> {
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
