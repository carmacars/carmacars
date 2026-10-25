// The stock photos' pure rules (migration 0137): the licence filter, the choice of a photo, the model years of each
// generation, and the credit, alt text and structured data of a stored photo.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { authorUrl, credit, firstModelYear, generationFor, generationRanges, imageObjectLd, licenceOk, photoAlt, pickBest, pickFor, plainAuthor, scoreCandidate,
  srcSet, type Candidate, type StockPhoto } from './stock-photos.ts';

const by = (LicenseShortName: string, extra: Record<string, string> = {}) => ({ LicenseShortName, Artist: '<a href="//commons.wikimedia.org/wiki/User:Example">Example</a>', ...extra });

test('licences: public domain, CC0, CC BY and CC BY-SA pass, with the licence page', () => {
  assert.deepEqual(licenceOk(by('CC BY-SA 4.0', { LicenseUrl: 'https://creativecommons.org/licenses/by-sa/4.0' })), { ok: true, licence: 'CC BY-SA 4.0', licenceUrl: 'https://creativecommons.org/licenses/by-sa/4.0', attribution: true });
  const two = licenceOk(by('CC BY 2.0'));
  assert.ok(two.ok && two.licence === 'CC BY 2.0' && two.licenceUrl === 'https://creativecommons.org/licenses/by/2.0/');
  assert.ok(licenceOk(by('CC BY-SA 3.0 de')).ok);
  assert.ok(licenceOk({ License: 'cc-by-sa-3.0' }).ok);
  const cc0 = licenceOk(by('CC0'));
  assert.ok(cc0.ok && cc0.licence === 'CC0' && !cc0.attribution);
  const pd = licenceOk(by('Public domain'));
  assert.ok(pd.ok && pd.licence === 'Public domain' && !pd.attribution);
  assert.ok(licenceOk({ License: 'pd' }).ok);
});

test('licences: non-commercial, no-derivatives, GFDL alone, fair use, unknown, non-free and personality rights are refused', () => {
  for (const l of ['CC BY-NC 2.0', 'CC BY-NC-SA 4.0', 'CC BY-ND 4.0', 'CC BY-NC-ND 3.0', 'GFDL', 'Fair use', 'Copyrighted', 'All rights reserved', 'FAL', ''])
    assert.equal(licenceOk(by(l)).ok, false, l);
  assert.equal(licenceOk(by('CC BY-SA 4.0', { NonFree: 'true' })).ok, false);
  assert.equal(licenceOk(by('CC BY-SA 4.0', { Restrictions: 'personality' })).ok, false);
  assert.equal(licenceOk(by('CC BY-SA 4.0', { Restrictions: 'trademarked' })).ok, true);
});

test('the author in plain text and its link', () => {
  assert.equal(plainAuthor('<a href="//commons.wikimedia.org/wiki/User:Mr.choppers" title="User:Mr.choppers">Mr.choppers</a>'), 'Mr.choppers');
  assert.equal(plainAuthor('<bdi><a href="https://www.flickr.com/people/x">Kevauto</a>\n</bdi>'), 'Kevauto');
  assert.equal(plainAuthor('Jo &amp; Sam'), 'Jo & Sam');
  assert.equal(authorUrl('<a href="//commons.wikimedia.org/wiki/User:Mr.choppers">Mr.choppers</a>'), 'https://commons.wikimedia.org/wiki/User:Mr.choppers');
  assert.equal(authorUrl('<a href="/wiki/User:A">A</a> and <a href="/wiki/User:B">B</a>'), null);
  assert.equal(authorUrl('Own work'), null);
});

const cand = (title: string, o: Partial<Candidate> = {}): Candidate => ({ title, width: 3000, height: 2000, mime: 'image/jpeg', meta: by('CC BY-SA 4.0'), ...o });
const ctx = { make: 'Toyota', model: 'Camry', yearFrom: 2018, yearTo: 2024 };

test('choosing: a front three-quarter view of the right model and years wins; rear, interior, police, toys and drawings never', () => {
  const front = cand('File:2018 Toyota Camry (ASV70R) Ascent sedan (2018-08-27) 01.jpg');
  const rear = cand('File:2018 Toyota Camry (ASV70R) Ascent sedan (2018-08-27) 02.jpg');
  const fl = cand('File:Toyota Camry XV70 front left.jpg');
  assert.ok(scoreCandidate(fl, ctx)! > scoreCandidate(rear, ctx)!);
  assert.ok(scoreCandidate(front, ctx)! > scoreCandidate(rear, ctx)!);
  for (const t of ['File:2019 Toyota Camry rear.jpg', 'File:Toyota Camry interior.jpg', 'File:Toyota Camry police car.jpg', 'File:Toyota Camry diecast toy.jpg',
    'File:Toyota Camry NASCAR.jpg', 'File:Toyota Camry Heckansicht.jpg', 'File:Toyota Camry engine bay.jpg', 'File:Toyota Camry taxi Toronto.jpg'])
    assert.equal(scoreCandidate(cand(t), ctx), null, t);
});

test('choosing: licence, size, shape and format are checked; the Wikidata image and quality images come first', () => {
  assert.equal(scoreCandidate(cand('File:Toyota Camry front.jpg', { meta: by('CC BY-NC 2.0') }), ctx), null);
  assert.equal(scoreCandidate(cand('File:Toyota Camry front.jpg', { width: 800, height: 500 }), ctx), null);
  assert.equal(scoreCandidate(cand('File:Toyota Camry front.jpg', { width: 2000, height: 2000 }), ctx), null);
  assert.equal(scoreCandidate(cand('File:Toyota Camry front.svg', { mime: 'image/svg+xml' }), ctx), null);
  assert.equal(scoreCandidate(cand('File:Toyota Camry front.jpg', { meta: { LicenseShortName: 'CC BY 4.0' } }), ctx), null, 'CC BY with no author');
  assert.notEqual(scoreCandidate(cand('File:Toyota Camry front.jpg', { meta: { LicenseShortName: 'Public domain' } }), ctx), null, 'public domain needs no author');
  const plain = cand('File:Toyota Camry 2020 front.jpg');
  const wd = cand('File:Toyota Camry 2020 seen in town.jpg', { wikidata: true });
  assert.notEqual(scoreCandidate(wd, ctx), null);
  const qi = cand('File:Toyota Camry 2020 parked.jpg', { quality: true });
  assert.ok(scoreCandidate(wd, ctx)! > scoreCandidate(plain, ctx)!);
  assert.ok(scoreCandidate(qi, ctx)! > scoreCandidate(cand('File:Toyota Camry 2020 parked.jpg'), ctx)!);
  // a photo dated years before the generation is the previous car
  assert.ok(scoreCandidate(cand('File:2016 Toyota Camry front.jpg'), ctx)! < scoreCandidate(cand('File:2021 Toyota Camry front.jpg'), ctx)!);
  // a file that never names the model may show another car; a twin under another name is not the model
  assert.equal(scoreCandidate(cand('File:Parking lot front view.jpg'), ctx), null);
  assert.equal(scoreCandidate(cand('File:2021 GMC Yukon front.jpg'), { make: 'Chevrolet', model: 'Tahoe' }), null);
  assert.notEqual(scoreCandidate(cand('File:2027 Chevrolet Bolt front.jpg'), { make: 'Chevrolet', model: 'Bolt EV' }), null);
  // years: a photo dated well before the generation, or a photo of the model in general from long ago, never
  assert.equal(scoreCandidate(cand('File:2009 Toyota Camry front.jpg'), ctx), null);
  assert.equal(scoreCandidate(cand('File:1972 Ford Maverick front.jpg'), { make: 'Ford', model: 'Maverick', minYear: 2013 }), null);
  assert.notEqual(scoreCandidate(cand('File:2023 Ford Maverick front.jpg'), { make: 'Ford', model: 'Maverick', minYear: 2013 }), null);
});

test('choosing: the best one, never a rejected file', () => {
  const a = cand('File:Toyota Camry 2020 front.jpg'), b = cand('File:Toyota Camry 2020 front 2.jpg', { quality: true });
  assert.equal(pickBest([a, b], ctx)!.c.title, b.title);
  assert.equal(pickBest([a, b], { ...ctx, rejected: [b.title] })!.c.title, a.title);
  assert.equal(pickBest([cand('File:Toyota Camry rear.jpg')], ctx), null);
});

test('generations: the first model year follows production (autumn starts are next year\'s model)', () => {
  assert.equal(firstModelYear({ id: 'a', label: 'x', start: 2017, end: null }), 2018);
  assert.equal(firstModelYear({ id: 'a', label: 'x', start: 2017, startMonth: 9, end: null }), 2018);
  assert.equal(firstModelYear({ id: 'a', label: 'x', start: 2019, startMonth: 2, end: null }), 2019);
  assert.equal(firstModelYear({ id: 'a', label: 'x', start: null, end: null }), null);
});

test('generations: model year ranges, gaps, duplicates and the catalog\'s years', () => {
  const camry = [
    { id: 'Q1', label: 'Toyota Camry (XV40)', start: 2006, end: 2011 },
    { id: 'Q2', label: 'Toyota Camry (XV50)', start: 2011, startMonth: 8, end: 2017 },
    { id: 'Q3', label: 'Toyota Camry (XV70)', start: 2017, end: null, image: 'x.jpg' },
    { id: 'Q3b', label: 'Toyota Camry (XV70) sedan', start: 2017, end: null },
    { id: 'Q0', label: 'Toyota Camry undated', start: null, end: null }
  ];
  const r = generationRanges(camry, 2000, 2025);
  // an undated generation exists (Q0): the newest dated one's open end is 5 model years
  assert.deepEqual(r.map((x) => [x.id, x.from, x.to]), [['Q1', 2007, 2011], ['Q2', 2012, 2017], ['Q3', 2018, 2022]]);
  assert.deepEqual(generationRanges(camry.filter((g) => g.id !== 'Q0'), 2000, 2025).map((x) => [x.id, x.to]).pop(), ['Q3', 2025]);
  // the newest generation with no end: 8 model years at most (a newer one Wikidata does not list gets no photo)
  assert.deepEqual(generationRanges([{ id: 'E120', label: 'Corolla E120', start: 2000, end: null }], 2000, 2027).map((x) => [x.from, x.to]), [[2000, 2008]]);
  assert.equal(generationFor(r, 2017)!.id, 'Q2');
  assert.equal(generationFor(r, 2018)!.id, 'Q3');
  assert.equal(generationFor(r, 2003), null, 'no generation: no photo for that year');
  // a model that was not made for some years: the old one ends a year after its production, the gap has no photo
  const ranger = generationRanges([{ id: 'A', label: 'Ranger (P273)', start: 1997, end: 2011 }, { id: 'B', label: 'Ranger (T6)', start: 2018, end: null }], 1998, 2024);
  assert.deepEqual(ranger.map((x) => [x.id, x.from, x.to]), [['A', 1998, 2012], ['B', 2019, 2024]]);
  assert.equal(generationFor(ranger, 2015), null);
  // a generation sold from the spring as that year's model: the catalog's first year is a year before it
  const m3 = generationRanges([{ id: 'M3', label: 'Tesla Model 3', start: 2017, end: null }], 2017, 2025);
  assert.deepEqual(m3.map((x) => [x.from, x.to]), [[2017, 2025]]);
  // clipped to the catalog
  assert.deepEqual(generationRanges(camry, 2015, 2020).map((x) => [x.id, x.from, x.to]), [['Q2', 2015, 2017], ['Q3', 2018, 2020]]);
  // the Camry as Wikidata had it on October 24, 2026: the XV50 dated, the XV70 not; the XV50 never reaches 2018
  assert.deepEqual(generationRanges([{ id: 'XV50', label: 'Toyota Camry (XV50)', start: 2011, end: null }, { id: 'XV70', label: 'Toyota Camry (XV70)', start: null, end: null }], 2000, 2027)
    .map((x) => [x.from, x.to]), [[2012, 2016]]);
});

const photo: StockPhoto = { id: '1', make: 'toyota', model: 'camry', make_name: 'Toyota', model_name: 'Camry', year_from: 2018, year_to: 2024, generation: 'Toyota Camry (XV70)',
  path: 'seo-photos/toyota/camry/2018-2024', sizes: [640, 1280], width: 1280, height: 853, author: 'Mr.choppers', licence: 'CC BY-SA 4.0',
  licence_url: 'https://creativecommons.org/licenses/by-sa/4.0/', source_url: 'https://commons.wikimedia.org/wiki/File:Camry.jpg' };

test('a stored photo: credit, alt text, srcset and ImageObject', () => {
  assert.equal(credit(photo).text, 'Photo: Mr.choppers, CC BY-SA 4.0, Wikimedia Commons');
  assert.equal(photoAlt(photo), 'Toyota Camry of the 2018 to 2024 generation');
  assert.equal(photoAlt({ ...photo, year_from: null, year_to: null }), 'Toyota Camry');
  const u = (p: string) => `https://files.example/${p}`;
  assert.equal(srcSet(photo, u), 'https://files.example/seo-photos/toyota/camry/2018-2024-640.webp 640w, https://files.example/seo-photos/toyota/camry/2018-2024-1280.webp 1280w');
  const ld = imageObjectLd(photo, u, 'A caption');
  assert.equal(ld['@type'], 'ImageObject');
  assert.equal(ld.contentUrl, 'https://files.example/seo-photos/toyota/camry/2018-2024-1280.webp');
  assert.equal(ld.width, 1280);
  assert.equal(ld.height, 853);
  assert.equal(ld.license, 'https://creativecommons.org/licenses/by-sa/4.0/');
  assert.equal(ld.creditText, 'Photo: Mr.choppers, CC BY-SA 4.0, Wikimedia Commons');
  assert.equal(ld.acquireLicensePage, photo.source_url);
});

test('one generic photo per page, the same each time', () => {
  assert.equal(pickFor([], 'x'), null);
  assert.equal(pickFor(['a', 'b', 'c'], '/car-rental/toronto'), pickFor(['a', 'b', 'c'], '/car-rental/toronto'));
});

test('generic photos: about the page\'s subject, nothing misleading', async () => {
  const { scoreGeneric } = await import('./stock-photos.ts');
  const road = { must: ['highway', 'traffic'] };
  assert.notEqual(scoreGeneric(cand('File:Highway 401 traffic at dusk.jpg'), road), null);
  assert.equal(scoreGeneric(cand('File:Straw texture.jpg'), road), null, 'a search hit on a stray word');
  assert.equal(scoreGeneric(cand('File:Highway 401 crash.jpg'), road), null);
  assert.equal(scoreGeneric(cand('File:Abandoned car on the highway.jpg'), road), null);
  assert.equal(scoreGeneric(cand('File:Highway 401 traffic.jpg', { meta: by('CC BY-ND 2.0') }), road), null);
  assert.ok(scoreGeneric(cand('File:Highway 401 traffic.jpg', { quality: true }), road)! > scoreGeneric(cand('File:Highway 401 traffic.jpg'), road)!);
});

test('Wikipedia: generation sections, model years first (North America), production, images, main articles', async () => {
  const { parseGenerations, generationRanges, yearSpan, wikiPlain, articleYears, categoryFor } = await import('./stock-photos.ts');
  assert.deepEqual(yearSpan('December 2018 – present'), { from: 2018, fromMonth: 12, to: null, current: true });
  assert.deepEqual(yearSpan('2012–2018 (Japan)\n2013–2018 (North America)'), { from: 2013, fromMonth: null, to: 2018, current: false });
  assert.equal(wikiPlain("{{nowrap|1996–2000}}<ref>x</ref> ([[North America]])"), '1996–2000 (North America)');
  const wt = `Intro text.
== First generation (XA10; 1994) ==
{{Main|Toyota RAV4 (XA10)}}
{{Infobox automobile
| name = First generation (XA10)
| image = 1994 Toyota RAV4 (SXA10) 3-door wagon (2010-09-08).jpg
| production = May 1994 – 2000
| model_years = 1996–2000 (North America)
}}
== Fourth generation (XA40; 2012) ==
{{Infobox automobile
| image = [[File:2013 Toyota RAV4.jpg]]
| production = 2012–2018<ref>a</ref>
}}
== Fifth generation (XA50; 2018) ==
{{Main|Toyota RAV4 (XA50)}}
{{Infobox automobile
| image = 2019 Toyota RAV4 LE front.jpg
| production = December 2018 – present
| model_years = 2019–present
}}
== Sixth generation (XA60; 2025) ==
{{Main|Toyota RAV4 (XA60)}}
== Sales ==
| production = 2020
== Safety ==
`;
  const g = parseGenerations(wt);
  assert.deepEqual(g.map((x) => [x.code, x.myFrom ?? null, x.start, x.current, x.image, x.main]), [
    ['XA10', 1996, 1994, false, 'File:1994 Toyota RAV4 (SXA10) 3-door wagon (2010-09-08).jpg', 'Toyota RAV4 (XA10)'],
    ['XA40', null, 2012, false, 'File:2013 Toyota RAV4.jpg', null],
    ['XA50', 2019, 2018, true, 'File:2019 Toyota RAV4 LE front.jpg', 'Toyota RAV4 (XA50)'],
    ['XA60', null, 2025, false, null, 'Toyota RAV4 (XA60)']
  ]);
  // XA40 production 2012 (month unknown): model year 2013; XA50 from 2019 to the year before the XA60 (2026)
  assert.deepEqual(generationRanges(g, 1995, 2027).map((x) => [x.code, x.from, x.to]), [['XA10', 1996, 2000], ['XA40', 2013, 2018], ['XA50', 2019, 2025], ['XA60', 2026, 2027]]);
  // a generation's own article fills what the main article lacks
  assert.deepEqual(articleYears('{{Infobox automobile\n| image = Camry XV70.jpg\n| production = August 2017 – 2024\n| model_years = 2018–2024\n}}'),
    { start: 2017, startMonth: 8, end: 2024, myFrom: 2018, myTo: 2024, current: false, image: 'File:Camry XV70.jpg' });
  // headings without a code: ordinals with a year; the Commons category by code or ordinal
  const civic = parseGenerations('== Tenth generation (2015) ==\n{{Infobox automobile\n| model_years = 2016–2021\n}}\n== Eleventh generation (FE/FL; 2021) ==\n{{Infobox automobile\n| model_years = 2022–present\n}}');
  assert.deepEqual(generationRanges(civic, 2010, 2027).map((x) => [x.label, x.from, x.to]), [['Tenth generation (2015)', 2016, 2021], ['Eleventh generation (FE/FL; 2021)', 2022, 2027]]);
  const cats = ['Category:Honda Civic (tenth generation)', 'Category:Honda Civic (eleventh generation)', 'Category:Toyota RAV4 (XA50)'];
  assert.equal(categoryFor(civic[0]!, cats), 'Category:Honda Civic (tenth generation)');
  assert.equal(categoryFor({ code: 'XA50', label: 'Fifth generation (XA50; 2018)' }, cats), 'Category:Toyota RAV4 (XA50)');
});

test('Openverse: the licence in Commons words, checked again at the source page; the credit names the source; the year note', async () => {
  const { openverseMeta, sourceShowsLicence, licenceOk, approxNote, credit } = await import('./stock-photos.ts');
  assert.deepEqual(licenceOk(openverseMeta('by-sa', '2.0', 'Jane')), { ok: true, licence: 'CC BY-SA 2.0', licenceUrl: 'https://creativecommons.org/licenses/by-sa/2.0/', attribution: true });
  assert.equal(licenceOk(openverseMeta('pdm', null, null)).ok, true);
  assert.equal(licenceOk(openverseMeta('by-nc', '2.0', 'Jane')).ok, false);
  assert.equal(sourceShowsLicence('<a href="https://creativecommons.org/licenses/by-sa/2.0/">Some rights reserved</a>', 'by-sa', '2.0'), true);
  assert.equal(sourceShowsLicence('<a href="https://creativecommons.org/licenses/by-nc-sa/2.0/">x</a>', 'by-sa', '2.0'), false);
  assert.equal(sourceShowsLicence('All rights reserved', 'by', '2.0'), false);
  assert.equal(credit({ ...photo, source_name: 'Flickr via Openverse' }).text, 'Photo: Mr.choppers, CC BY-SA 4.0, Flickr via Openverse');
  assert.equal(approxNote({ ...photo, match: 'exact' }), null);
  assert.equal(approxNote({ ...photo, match: 'model' }), 'Representative photo of the Toyota Camry, not the exact year');
});
