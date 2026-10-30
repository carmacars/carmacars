// The ServiceOntario forms filled for real (docs/changes/2026-10-23-form-fillers.md): the publisher's downloads byte for
// byte (tests/fixtures/official-forms, as the forms-fetch workflow downloads them, encrypted as published), the mapping
// of migration 0122 (maps.generated.json), and the registry context of four cars in the four onboarding methods
// (contexts.json, read from the database).
// The owner's rule (October 23, 2026): the filled form is the official PDF unchanged except its empty text boxes. The
// filled file is compared with the official one object by object: the same bytes first, the same pages and content
// streams, and the update after them holds only the values (and their appearances) of the text fields filled; no
// checkbox, drop-down, signature, page, annotation, image or font is added or changed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fillPdf, readFields, type Spec } from './fill.ts';
import { NOT_MAPPED, notMapped } from './not-mapped.ts';
import { Pdf, acroForm, fields, filledValues, get, pages, packetText, xfaPackets, xmlTree, type V, type XNode } from './pdf-update.ts';

const FIX = new URL('../../../tests/fixtures/official-forms/', import.meta.url);
const MAPS = JSON.parse(readFileSync(new URL('./maps.generated.json', import.meta.url), 'utf8')) as Record<string, { kind: string; map: Record<string, Spec> }>;
const CTX = JSON.parse(readFileSync(new URL('contexts.json', FIX), 'utf8')) as Record<string, Record<string, unknown>>;
const REPORT = JSON.parse(readFileSync(new URL('../../../../docs/forms/official-forms.json', import.meta.url), 'utf8')) as { forms: Array<{ code: string; original_sha256: string; pages: number }> };
const pdf = (code: string) => new Uint8Array(readFileSync(new URL(`${code}.pdf`, FIX)));

// what app.fill_government_form does with a mapping and a context (0022, 0042; the transforms of app.apply_transform)
const at = (c: unknown, path: string) => { const v = path.split('.').reduce<unknown>((o, k) => (o && typeof o === 'object' ? (o as Record<string, unknown>)[k] : undefined), c); return v === null || v === undefined || String(v).trim() === '' ? null : String(v); };
function transform(v: string | null, t?: string): string | null {
  if (v === null) return null;
  if (!t) return v;
  if (t === 'upper') return v.toUpperCase();
  if (t === 'postal') { const p = v.replace(/\s/g, '').toUpperCase(); return /^[A-Z]\d[A-Z]\d[A-Z]\d$/.test(p) ? `${p.slice(0, 3)} ${p.slice(3)}` : v.toUpperCase(); }
  if (t === 'phone') { const d = v.replace(/\D/g, ''); const n = /^1?\d{10}$/.test(d) ? d.slice(-10) : null; return n ? `(${n.slice(0, 3)}) ${n.slice(3, 6)}-${n.slice(6)}` : v; }
  if (t === 'date:YYYY/MM/DD') return v.slice(0, 10).replace(/-/g, '/');
  throw new Error(`transform ${t}`);
}
function valuesFor(ctx: Record<string, unknown>, map: Record<string, Spec>): Record<string, string | null> {
  const out: Record<string, string | null> = {};
  for (const [name, s] of Object.entries(map)) {
    if (s.when && at(ctx, s.when) !== 'true') continue;
    let v = s.source ? transform(at(ctx, s.source), s.transform) : null;
    if (s.type === 'checkbox') v = v === 'true' || v === 'Yes' ? 'Yes' : 'Off';
    out[name] = v;
  }
  return out;
}
const SCEN = { S1: 'S1_lease_existing_corporation', S2: 'S2_lease_new_corporation', S3: 'S3_co_registrant', S6: 'S6_transfer_leased' } as const;
const FORMS_OF: Record<keyof typeof SCEN, string[]> = { S1: ['SR-LV-006', 'SR-LV-012'], S2: ['SR-LV-006', 'SR-LV-012', 'ON00453', '013-0169', '013-1155'], S3: ['SR-LV-006', 'SR-LV-012'], S6: ['SR-LV-006', 'SR-LV-012'] };
const fill = async (code: string, s: keyof typeof SCEN) => {
  const values = valuesFor(CTX[SCEN[s]]!, MAPS[code]!.map);
  return { values, ...(await fillPdf(pdf(code), values, MAPS[code]!.map)) };
};
const P1 = 'form1[0].page1[0].body[0].';

// ---------------------------------------------------------------- the comparison with the official PDF
const norm = (v: V | undefined): unknown => v === undefined ? undefined : v.t === 'str' ? `str:${Buffer.from(v.bytes).toString('hex')}` : v.t === 'arr' ? v.items.map(norm)
  : v.t === 'dict' ? Object.fromEntries(v.entries.map(([k, x]) => [k, norm(x)]).sort(([a], [b]) => String(a).localeCompare(String(b)))) : v.t === 'ref' ? `ref:${v.num} ${v.gen}` : v.t === 'num' ? `num:${v.raw}` : JSON.stringify(v);
const without = (v: V, keys: string[]) => ({ ...(norm(v) as Record<string, unknown>), ...Object.fromEntries(keys.map((k) => [k, undefined])) });
function leaves(xml: string): Array<[string, string]> {
  const t = xmlTree(xml); const out: Array<[string, string]> = [];
  const walk = (n: XNode, path: string) => n.children.forEach((c, i) => { const p = `${path}/${c.name}#${i}`; if (c.children.length) walk(c, p); else out.push([p, c.self ? '' : xml.slice(c.openEnd, c.closeStart)]); });
  walk(t, '');
  return out;
}

/** The filled file against the official one: the official bytes first, unchanged; the same pages; and in the update
 *  only the filled text fields (their /V and /AP), the appearance streams they point to, and the switch of the form's
 *  XFA copy (a hybrid form) or the XFA data with the values (an XFA-only form). */
async function onlyTextBoxesChanged(code: string, original: Uint8Array, out: Awaited<ReturnType<typeof fill>>) {
  const filled = out.bytes;
  assert.deepEqual(Buffer.from(filled.subarray(0, original.length)), Buffer.from(original), `${code}: the official PDF's bytes come first, unchanged`);
  if (!out.filled.length) { assert.equal(filled.length, original.length, `${code}: nothing filled, nothing added`); return; }
  const a = await Pdf.open(original); const b = await Pdf.open(filled);
  const pa = await pages(a); const pb = await pages(b);
  assert.deepEqual(pb, pa, `${code}: the same pages, in the same order`);
  const updated = [...b.xref.entries()].filter(([, e]) => e.kind === 'off' && e.off >= original.length).map(([n]) => n);
  for (const p of pa) assert.ok(!updated.includes(p), `${code}: page object ${p} (its content streams and annotations) unchanged`);
  const fa = await fields(a); const byNum = new Map<number, (typeof fa)[number]>();
  for (const f of fa) { byNum.set(f.num, f); for (const w of f.widgets) byNum.set(w.num, f); }
  const filledNames = new Set(out.filled);
  const { formNum } = await acroForm(a); const { form } = await acroForm(a);
  const packets = await xfaPackets(a, form); const ds = packets.get('datasets');
  const apRefs = new Set<number>();
  for (const n of updated) {
    const ob = (await b.obj(n))!;
    if (nameOf(get(ob.value, 'Type')) === 'XRef') continue;
    const oa = await a.obj(n);
    if (!oa) continue; // a new object: checked below as an appearance stream
    const f = byNum.get(n);
    if (f) {
      assert.equal(f.kind, 'text', `${code}: object ${n} is a text field (${f.name}), never a ${f.kind}`);
      assert.ok(filledNames.has(f.name), `${code}: ${f.name} was filled`);
      assert.deepEqual(without(ob.value, ['V', 'AP']), without(oa.value, ['V', 'AP']), `${code}: ${f.name}: only its value and appearance change`);
      const ap = get(get(ob.value, 'AP'), 'N'); if (ap?.t === 'ref') apRefs.add(ap.num);
      continue;
    }
    if (n === formNum) {
      assert.deepEqual(without(ob.value, ['XFA']), without(oa.value, ['XFA']), `${code}: the form dictionary: only its XFA copy switched off`);
      assert.equal(get(ob.value, 'XFA'), undefined);
      continue;
    }
    if (ds?.t === 'ref' && n === ds.num) {
      assert.deepEqual(without(ob.value, ['Length', 'Filter', 'DecodeParms']), without(oa.value, ['Length', 'Filter', 'DecodeParms']), `${code}: the XFA data stream keeps its dictionary`);
      const xa = (await packetText(a, ds))!; const xb = (await packetText(b, ds))!;
      const la = leaves(xa); const lb = leaves(xb);
      assert.deepEqual(lb.map(([p]) => p), la.map(([p]) => p), `${code}: the XFA data keeps every node, in order`);
      const changed = lb.filter(([, t], i) => t !== la[i]![1]).map(([, t]) => t);
      assert.equal(changed.length, out.filled.length, `${code}: one data node per value`);
      continue;
    }
    assert.fail(`${code}: object ${n} changed and is not a filled text field`);
  }
  for (const n of updated) {
    if (await a.obj(n)) continue;
    const ob = (await b.obj(n))!;
    if (nameOf(get(ob.value, 'Type')) === 'XRef') continue;
    assert.equal(nameOf(get(ob.value, 'Subtype')), 'Form', `${code}: new object ${n} is an appearance stream`);
    assert.ok(apRefs.has(n), `${code}: appearance ${n} belongs to a filled field`);
  }
  // the fields that were not filled are the official ones, untouched: every checkbox, drop-down, radio and signature
  const fb = await fields(b);
  for (const f of fb) if (f.kind !== 'text' || !filledNames.has(f.name)) assert.ok(!updated.includes(f.num) && f.widgets.every((w) => !updated.includes(w.num)), `${code}: ${f.name} (${f.kind}) untouched`);
}
const nameOf = (v: V | undefined) => (v?.t === 'name' ? v.raw : undefined);

test('the fixtures are the publisher\'s downloads, byte for byte', async () => {
  const { createHash } = await import('node:crypto');
  for (const f of REPORT.forms) assert.equal(createHash('sha256').update(pdf(f.code)).digest('hex'), f.original_sha256, f.code);
});

test('every mapped field is a field of the official PDF, of the same type; every text value fits its field', async () => {
  for (const [code, { map }] of Object.entries(MAPS)) {
    const { fields: fs, xfaOnly } = await readFields(pdf(code));
    const byName = new Map(fs.map((f) => [f.name, f]));
    for (const [name, s] of Object.entries(map)) {
      const f = byName.get(name);
      assert.ok(f, `${code}: ${name} is in the PDF`);
      if (s.type === 'checkbox' && !xfaOnly) assert.equal(f.type, 'checkbox', `${code}: ${name} is a checkbox`);
      if (s.type === 'dropdown') assert.equal(f.type, 'dropdown', `${code}: ${name} is a drop-down`);
      if ((s.type ?? 'text') === 'text') assert.equal(f.type, 'text', `${code}: ${name} is a text box`);
    }
  }
  for (const s of Object.keys(SCEN) as Array<keyof typeof SCEN>) for (const code of FORMS_OF[s]) {
    const out = await fill(code, s);
    assert.deepEqual(out.missing, [], `${s} ${code}: every value found its field`);
    assert.deepEqual(out.truncated, [], `${s} ${code}: no value cut at the field's length`);
  }
});

// Release 21b, item 8: the form-completeness audit. Every field of each publisher's PDF is mapped or deliberately left
// empty with its reason (not-mapped.ts); a rule that matches nothing, or a mapped field, is stale.
test('no unmapped field: every field of every official PDF is mapped or left empty on purpose, with the reason', async () => {
  for (const [code, { map }] of Object.entries(MAPS)) {
    const { fields: fs } = await readFields(pdf(code));
    const open = fs.filter((f) => !(f.name in map) && !notMapped(code, f.name, f.type)).map((f) => `${f.type} ${f.name}`);
    assert.deepEqual(open, [], `${code}: fields neither mapped nor left empty on purpose`);
    for (const r of NOT_MAPPED[code] ?? []) {
      const hits = fs.filter((f) => (r.type ? r.type === f.type : true) && r.match.test(f.name));
      assert.ok(hits.some((f) => !(f.name in map)), `${code}: the rule "${r.reason}" matches no unmapped field`);
      if (!r.type) assert.deepEqual(hits.filter((f) => f.name in map).map((f) => f.name), [], `${code}: the rule "${r.reason}" matches a mapped field`);
    }
  }
  assert.deepEqual(Object.keys(NOT_MAPPED).sort(), Object.keys(MAPS).sort());
});

test('the filled form is the official PDF unchanged except its filled text boxes (every form, every method)', async () => {
  for (const s of Object.keys(SCEN) as Array<keyof typeof SCEN>) for (const code of FORMS_OF[s]) {
    const out = await fill(code, s);
    assert.ok(out.filled.length > 0, `${s} ${code}: something filled`);
    await onlyTextBoxesChanged(`${s} ${code}`, pdf(code), out);
    // what the mapping marks as a checkbox, a drop-down or a signature is left for the counter
    for (const [n, sp] of Object.entries(MAPS[code]!.map)) if (sp.type && sp.type !== 'text') assert.ok(!out.filled.includes(n), `${s} ${code}: ${n} (${sp.type}) is done by hand`);
  }
});

test('the filled forms open in another PDF reader (pdf.js) with the values in their fields, encrypted as published', async () => {
  const pdfjs = await import('pdfjs-dist/legacy/build/pdf.mjs');
  for (const code of ['SR-LV-006', 'SR-LV-012', '013-0169', '013-1155']) {
    const out = await fill(code, 'S2');
    const d = await pdfjs.getDocument({ data: out.bytes.slice(), verbosity: 0 }).promise;
    assert.equal(d.numPages, REPORT.forms.find((f) => f.code === code)!.pages);
    const objs = (await d.getFieldObjects()) ?? {};
    for (const n of out.filled) assert.equal(String((objs[n] as Array<{ value: unknown }> | undefined)?.[0]?.value ?? ''), out.values[n], `${code}: ${n}`);
    const annots = await (await d.getPage(1)).getAnnotations();
    const first = annots.find((x: { fieldName?: string }) => x.fieldName === out.filled[0]) as { hasAppearance?: boolean } | undefined;
    assert.ok(first?.hasAppearance, `${code}: the first filled field has its appearance`);
  }
});

const text = async (bytes: Uint8Array, name: string) => (await filledValues(bytes))[name] ?? '';

test('SR-LV-006 under a Lease: the owner\'s corporation is the registrant, its address in four boxes, the VIN in section 7', async () => {
  const d = (await fill('SR-LV-006', 'S2')).bytes;
  assert.equal(await text(d, `${P1}personalInfo[0].#subform[0].lastName[2]`), 'TREMBLAY MOBILITY INC.');
  assert.equal(await text(d, `${P1}personalInfo[0].#subform[0].streetName[0]`), '1204 Bay Street');
  assert.equal(await text(d, `${P1}personalInfo[0].#subform[0].apt[0]`), '1807');
  assert.equal(await text(d, `${P1}personalInfo[0].#subform[0].city[0]`), 'Toronto');
  assert.equal(await text(d, `${P1}personalInfo[0].#subform[0].postalCode[0]`), 'M5R 2A5');
  assert.equal(await text(d, `${P1}personalInfo[0].#subform[0].lastName[0]`), '', 'a new corporation\'s RIN is written in at the counter (ON00453, the same visit)');
  assert.equal(await text(d, `${P1}personalInfo[0].#subform[0].#subform[1].date[0]`), '', 'a company has no date of birth');
  assert.equal(await text(d, `${P1}businessInfo6[0].#field[0]`), 'W1KAF4HB5MR123456', 'section 7 names the VIN');
  assert.equal(await text(d, `${P1}businessInfo7[0].esoName[0]`), 'OLIVIA MARGARET TREMBLAY');
  assert.equal(await text(d, `${P1}businessInfo7[0].date[0]`), '', 'the date of an ink signature is written when it is signed');
  const s1 = (await fill('SR-LV-006', 'S1')).bytes;
  assert.equal(await text(s1, `${P1}personalInfo[0].#subform[0].lastName[0]`), 'C9876-54321', 'the corporation\'s RIN on record, never a person\'s licence');
  assert.equal(await text(s1, `${P1}personalInfo[0].#subform[0].apt[0]`), '2500');
  assert.equal(await text(s1, `${P1}businessInfo7[0].esoName[0]`), 'DANIEL OKAFOR', 'the signing officer signs for the corporation');
});

test('SR-LV-006 under Co-Registrant and under a Transfer of a leased car (CarmaCars\' signing officer signs section 8)', async () => {
  const co = (await fill('SR-LV-006', 'S3')).bytes;
  assert.equal(await text(co, `${P1}personalInfo[0].#subform[0].lastName[2]`), 'TREMBLAY, OLIVIA M');
  assert.equal(await text(co, `${P1}personalInfo[0].#subform[0].lastName[0]`), 'T6512-48390-85421');
  assert.equal(await text(co, `${P1}personalInfo[0].#subform[0].#subform[1].date[0]`), '1985/02/03');
  const tr = (await fill('SR-LV-006', 'S6')).bytes;
  assert.equal(await text(tr, `${P1}personalInfo[0].#subform[0].lastName[2]`), 'BMW FINANCIAL SERVICES');
  assert.equal(await text(tr, `${P1}businessInfo7[0].esoName[0]`), 'ABBAS AL-MASHITA');
});

test('SR-LV-012: section 1 names CarmaCars as the plate owner only when it holds the plates; section 2 only for two registrants', async () => {
  const lease = (await fill('SR-LV-012', 'S2')).bytes;
  assert.equal(await text(lease, `${P1}personalInfo[0].#subform[0].lastName[3]`), '18122211 CANADA INC.');
  assert.equal(await text(lease, `${P1}personalInfo[0].#subform[0].lastName[0]`), 'R1234-56789');
  assert.equal(await text(lease, `${P1}personalInfo[0].#subform[0].streetName[0]`), '2967 Dundas St W', 'the street line alone, not the whole address');
  assert.equal(await text(lease, `${P1}personalInfo[0].#subform[0].apt[0]`), '208B');
  assert.equal(await text(lease, `${P1}personalInfo[0].#subform[0].city[0]`), 'Toronto');
  assert.equal(await text(lease, `${P1}personalInfo[0].#subform[0].postalCode[0]`), 'M6P 1Z2');
  assert.equal(await text(lease, `${P1}businessInfo[0].#subform[0].lastName[3]`), '', 'section 2 stays empty');
  const co = (await fill('SR-LV-012', 'S3')).bytes;
  assert.equal(await text(co, `${P1}personalInfo[0].#subform[0].lastName[3]`), '', 'section 1 stays empty');
  assert.equal(await text(co, `${P1}businessInfo[0].#subform[0].lastName[3]`), 'TREMBLAY, OLIVIA M');
  assert.equal(await text(co, `${P1}businessInfo[0].#subform[0].apt[0]`), '1807');
  assert.equal(await text(co, `${P1}businessInfo[0].#subform[4].lastName[7]`), '18122211 CANADA INC.');
  assert.equal(await text(co, `${P1}businessInfo[0].#subform[4].city[1]`), 'Toronto');
  assert.equal(await text(co, `${P1}businessInfo[0].esoName[1]`), 'ABBAS AL-MASHITA');
});

test('the tax forms and the RIN form: the owner and the corporation, street number and name apart, the phone as written', async () => {
  const c = await fill('013-0169', 'S2');
  assert.equal(await text(c.bytes, `${P1}SectionB[0].#subform[1].busStreetNo[0]`), '1204');
  assert.equal(await text(c.bytes, `${P1}SectionB[0].#subform[1].busStreetName[0]`), 'Bay Street');
  assert.equal(await text(c.bytes, `${P1}SectionB[0].#subform[1].TelephoneNo[0]`), '(416) 555-0142');
  assert.deepEqual(c.byHand, [`${P1}SectionB[0].#subform[1].busProvince[0]`], 'the province drop-down is chosen at the counter');
  const s = (await fill('013-1155', 'S2')).bytes;
  assert.equal(await text(s, 'nameRecipient'), 'TREMBLAY MOBILITY INC.');
  assert.equal(await text(s, 'nameDonor'), 'OLIVIA MARGARET TREMBLAY');
  assert.equal(await text(s, 'vehicleID'), 'W1KAF4HB5MR123456');
  // ON00453 is an Adobe dynamic form: its values are in its XFA data, the boxes to tick are left for the counter
  const rin = await fill('ON00453', 'S2');
  assert.equal(rin.xfaOnly, true);
  assert.equal(await text(rin.bytes, `${P1}orgName[0]`), 'TREMBLAY MOBILITY INC.');
  assert.equal(await text(rin.bytes, `${P1}telNo[0]`), '(416) 555-0142');
  assert.equal(await text(rin.bytes, `${P1}streetNo[0]`), '1204');
  assert.equal(await text(rin.bytes, `${P1}streetName[0]`), 'Bay Street');
  assert.equal(await text(rin.bytes, `${P1}new[0]`), '', 'never ticked');
  assert.deepEqual(rin.byHand.sort(), [`${P1}new[0]`, `${P1}operatedOut[0]`, `${P1}sig1[0].signature[0]`].sort());
});
