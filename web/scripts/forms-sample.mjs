// Fills every official registry form with sample data, as an owner would get it, so the draft mappings of 0047 can be
// looked at before an Admin presses "Checked: use for owners". Local stack only: inside one transaction that is rolled
// back, a sample car and its owner get a full fictional record (a person with a corporation, every method in turn), the
// database resolves each current template's values (app.form_field_values, the same as the owner portal), and each
// official PDF is filled in Node with the same code the browser uses (src/features/official-forms/fill.ts), with a
// sample drawn signature in the signature boxes. Writes <out>/<code>-<method>.pdf, a PNG of each page (pdftoppm, when
// installed) and <out>/summary.json (filled and left blank per form).
//
//   node --experimental-strip-types scripts/forms-sample.mjs --pdfs <dir of CODE.pdf> --out reports/forms
//
// The PDFs are the templates the forms-fetch workflow stored (documents bucket, forms/templates/<code>/...): download
// them first, or pass the forms-fetch run's files.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import postgres from 'postgres';
import sharp from 'sharp';
import { fillPdf } from '../src/features/official-forms/fill.ts';

const arg = (n, d) => { const i = process.argv.indexOf(n); return i > 0 ? process.argv[i + 1] : d; };
const PDFS = arg('--pdfs');
const OUT = arg('--out', 'reports/forms');
if (!PDFS) { console.error('--pdfs <dir> is required'); process.exit(2); }
mkdirSync(OUT, { recursive: true });
const sql = postgres(process.env.DATABASE_URL ?? 'postgresql://postgres@127.0.0.1:54322/carmacars', { max: 1, onnotice: () => {} });

// a signature drawn on a phone, as the signature pad saves it (PNG, transparent background)
const signature = await sharp(Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="600" height="160">
  <path d="M20 120 C 60 20, 90 20, 110 110 S 160 150, 190 60 S 250 30, 270 120 C 290 160, 330 40, 360 90 S 430 140, 470 70 L 580 60"
        fill="none" stroke="#1a1a2e" stroke-width="6" stroke-linecap="round"/></svg>`)).png().toBuffer();

const METHODS = ['co_registrant', 'lease_existing_corporation', 'transfer'];
const summary = [];
class Rollback extends Error {}
for (const method of METHODS) {
  try {
    await sql.begin(async (tx) => {
      const [v] = await tx`select v.id, v.owner_id from vehicles v join owners o on o.id = v.owner_id where o.kind = 'program' order by v.created_at limit 1`;
      if (!v) throw new Error('No program owner\'s car in the local database: run the seed first');
      await tx`update owners set owner_type = 'individual', legal_name = 'Priya Anand Shah', first_name = 'Priya', middle_name = 'Anand', last_name = 'Shah',
                 corporation_name = 'Shah Mobility Inc.', registrant_identification_number = null, address_line1 = '250 Front Street West', address_line2 = 'Unit 1204',
                 city = 'Toronto', province = 'ON', postal_code = 'm5v3g5', email = 'priya.shah@example.com', phone = '4165550123',
                 signing_officer_name = 'Priya Shah', signing_officer_title = 'President' where id = ${v.owner_id}`;
      await tx`insert into owner_private_details (owner_id, licence_number, licence_province, date_of_birth) values (${v.owner_id}, 'S1234-56789-01234', 'ON', '1986-03-14')
               on conflict (owner_id) do update set licence_number = excluded.licence_number, licence_province = excluded.licence_province, date_of_birth = excluded.date_of_birth`;
      await tx`update vehicles set vin = '2T1BURHE5KC123456', plate = 'CKRT 512', year = 2021, make = 'Toyota', model = 'Corolla', colour = 'Silver', odometer_km = 48210,
                 onboarding_method = ${method} where id = ${v.id}`;
      const held = method.startsWith('lease') ? 'corporation' : 'individual';
      await tx`update vehicle_onboardings set proposed_onboarding_method = ${method}, title_status = 'owned_outright', held_by = ${held} where vehicle_id = ${v.id}`;
      await tx`update vehicle_schedules set onboarding_method = ${method}, held_by = ${held} where vehicle_id = ${v.id} and superseded_by is null`;
      const templates = await tx`select id, form_code, file_key, field_map, kind from pdf_templates where is_current order by form_code`;
      for (const t of templates) {
        const file = path.join(PDFS, `${t.form_code}.pdf`);
        if (!existsSync(file)) { summary.push({ code: t.form_code, method, skipped: 'no PDF in --pdfs' }); continue; }
        const [{ values }] = await tx`select app.form_field_values(${t.id}, ${v.id}) as values`;
        const out = await fillPdf(readFileSync(file), values, t.field_map, { signaturePng: new Uint8Array(signature), flatten: true });
        const name = `${t.form_code}-${method}`;
        writeFileSync(path.join(OUT, `${name}.pdf`), out.bytes);
        let pngs = 0;
        try { execFileSync('pdftoppm', ['-r', '70', '-png', path.join(OUT, `${name}.pdf`), path.join(OUT, name)], { stdio: 'ignore' }); pngs = 1; } catch { pngs = 0; }
        const blank = Object.entries(values).filter(([, x]) => x === null || x === '').map(([k]) => k);
        summary.push({ code: t.form_code, method, kind: t.kind, mapped: Object.keys(t.field_map).length, filled: out.filled.length, blank, missing: out.missing, rendered: !!pngs });
        console.log(`${name}: ${out.filled.length} filled of ${Object.keys(t.field_map).length} mapped${blank.length ? `; empty for this owner: ${blank.length}` : ''}${out.missing.length ? `; not in the PDF: ${out.missing.join(', ')}` : ''}`);
      }
      throw new Rollback();
    });
  } catch (e) { if (!(e instanceof Rollback)) throw e; }
}
writeFileSync(path.join(OUT, 'summary.json'), JSON.stringify(summary, null, 1));
await sql.end();
