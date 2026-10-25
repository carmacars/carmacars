// A stand-in for Blind Spot's form, for the unit tests: Blind Spot's PDF is private (Admin > Settings > Forms) and is never
// in the repository. Same page size, the same pre-printed annotations at the same places (the old address top left and
// twice in box 15, "Full Value"), the old address, HST number and signature drawn where the real form has them.
// Relative imports with their extension: the unit tests run this file in Node directly.
import { PDFArray, PDFDocument, PDFName, PDFString, StandardFonts, rgb } from 'pdf-lib';
import { PAGE_H } from './layout.ts';

export /** A stand-in for Blind Spot's form: A4, two pages, the old address, HST number and "Sam" printed where the form has
 *  them, and FreeText annotations at the form's own rectangles (PDF coordinates). */
async function standIn(): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const p1 = doc.addPage([595.276, 841.89]);
  const p2 = doc.addPage([595.276, 841.89]);
  p1.drawRectangle({ x: 18.8, y: PAGE_H - 531.5, width: 270, height: 20, color: rgb(1, 186 / 255, 204 / 255) });
  p1.drawText('75756 2079 RT0001', { x: 64, y: PAGE_H - 120.5, size: 11, font });
  p1.drawText('Sam', { x: 145, y: PAGE_H - 821, size: 18, font });
  p1.drawText('15 RENTED FROM', { x: 22, y: PAGE_H - 521, size: 6, font });
  p2.drawText('TERMS AND CONDITIONS', { x: 50, y: 800, size: 12, font });
  const annots = doc.context.obj([]) as PDFArray;
  for (const [rect, text] of [[[49, 745, 286, 757], '104 CROCKFORD BLVD, TORONTO, ON, M1R 3C3'], [[23, 307, 91, 319], '104 Crockford Blvd'], [[209, 307, 277, 319], '104 Crockford Blvd'],
    [[70, 254, 105, 266], 'Full Value'], [[373, 372, 436, 384], 'UNDERAGE FEE']] as Array<[number[], string]>) {
    const a = doc.context.obj({ Type: 'Annot', Subtype: 'FreeText', Rect: rect, Contents: PDFString.of(text), DA: PDFString.of('/Helv 8 Tf 0 g'), F: 4 });
    annots.push(doc.context.register(a));
  }
  p1.node.set(PDFName.of('Annots'), annots);
  return doc.save();
}

