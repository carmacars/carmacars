// The places pipeline (migration 0095) on the test fixture: GeoNames, OpenStreetMap and the Census merged, kinds,
// parents and slugs decided from the data.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildPlaces, cityRadius, osmSrcId, parseCensusLine, parseGeonamesLine, parseOsmLine, regionCode, ringCentre, slugify, toCsv } from './gazetteer.ts';

const FIX = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../../scripts/places/fixtures');
const lines = (f: string) => fs.readFileSync(path.join(FIX, f), 'utf8').split('\n').filter(Boolean);
function build(regions: string[] | null = null) {
  const geonames = ['geonames/CA.txt', 'geonames/US.txt', 'geonames/MX.txt'].flatMap(lines).map(parseGeonamesLine).filter((x) => x !== null);
  const admin1Names = Object.fromEntries(lines('geonames/admin1CodesASCII.txt').map((l) => l.split('\t')).map((c) => [c[0]!, c[2]!]));
  const iata = Object.fromEntries(lines('geonames/alternateNames.txt').map((l) => l.split('\t')).filter((c) => c[2] === 'iata').map((c) => [Number(c[1]), c[3]!]));
  const osm = lines('osm/places.geojsonseq').map(parseOsmLine).filter((x) => x !== null);
  const cl = lines('census/Gaz_places_national.txt'); const header = cl[0]!.split('\t');
  const census = cl.slice(1).map((l) => parseCensusLine(l, header)).filter((x) => x !== null);
  return buildPlaces({ geonames, admin1Names, iata, osm, census, regions, fixture: true });
}

test('regions: Canada by GeoNames code, the US by postal code, Mexico by state name, territories under the US', () => {
  assert.equal(regionCode('CA', '08'), 'CA-ON');
  assert.equal(regionCode('US', 'NY'), 'US-NY');
  assert.equal(regionCode('MX', '14', 'Jalisco'), 'MX-JAL');
  assert.equal(regionCode('MX', '09', 'Ciudad de Mexico'), 'MX-CMX');
  assert.equal(regionCode('PR', '01'), 'US-PR');
  assert.equal(slugify('Montréal-Nord'), 'montreal-nord');
});

test('build: kinds, merges and parents from the data', () => {
  const r = build();
  const by = (name: string, kind?: number) => r.places.find((p) => p.name === name && (kind === undefined || p.kind === kind))!;
  const id = (name: string, kind?: number) => by(name, kind).src_id;
  // a small place inside a large city's radius is its neighbourhood; a GeoNames PPLX too
  assert.equal(by('Port Credit').kind, 6); assert.equal(by('Port Credit').parent_src_id, id('Mississauga'));
  assert.equal(by('Streetsville').kind, 6); assert.equal(by('Rexdale').parent_src_id, id('Toronto', 5));
  // large cities stay cities, under their region
  assert.equal(by('Mississauga').kind, 5); assert.equal(by('Mississauga').parent_src_id, id('Peel'));
  assert.equal(by('Kingston').kind, 5);
  // OpenStreetMap: the same place close by is merged (Port Credit), a new neighbourhood is added under its city
  assert.equal(r.merged.osm, 1);
  assert.ok((by('Port Credit').flags & 4) !== 0, 'Port Credit carries the OpenStreetMap flag');
  assert.equal(by('Liberty Village').kind, 6); assert.equal(by('Liberty Village').parent_src_id, id('Toronto', 5));
  assert.equal(by('Allentown').parent_src_id, id('Buffalo'));
  // the Census confirms Buffalo and adds Lackawanna (incorporated: never a neighbourhood); a CDP is not added
  assert.equal(r.merged.census, 1);
  assert.equal(by('Lackawanna').kind, 5);
  assert.ok(!r.places.some((p) => p.name === 'Cheektowaga'));
  // airports with their IATA code under their region; landmarks under the place around them
  assert.equal(by('Toronto Pearson International Airport').slug, 'yyz-airport');
  assert.equal(by('Toronto Pearson International Airport').parent_src_id, id('Peel'));
  assert.equal(by('CN Tower').parent_src_id, id('Toronto', 5));
  // slugs: unique and readable
  const slugs = r.places.map((p) => p.slug);
  assert.equal(new Set(slugs).size, slugs.length);
  assert.equal(by('Kingston').slug, 'kingston-on');
  assert.equal(by('Port Credit').slug, 'port-credit-mississauga-on');
  assert.equal(by('Guadalajara', 5).slug, 'guadalajara-jal');
  assert.deepEqual(Object.keys(r.counts).sort(), ['CA', 'MX', 'US']);
});

test('build: only the regions asked for; the CSV quotes names with commas', () => {
  const r = build(['US-NY']);
  assert.ok(r.places.every((p) => p.region_code === 'US-NY'));
  assert.match(toCsv([{ ...r.places[0]!, name: 'A, B' }]), /"A, B"/);
  assert.equal(cityRadius(5_000_000), 30);
  assert.equal(Math.round(cityRadius(2_600_000)), 25);
  assert.equal(cityRadius(1000), 3);
});

test('OpenStreetMap areas (0115): neighbourhoods mapped as ways and relations, at their middle, with ids of their own', () => {
  const area = (id: string, place: string, geometry: unknown) => JSON.stringify({ type: 'Feature', id, geometry, properties: { name: 'Leslieville', place } });
  const sq = { type: 'Polygon', coordinates: [[[-79.34, 43.66], [-79.32, 43.66], [-79.32, 43.67], [-79.34, 43.67], [-79.34, 43.66]]] };
  const w = parseOsmLine(area('w1001', 'neighbourhood', sq))!;
  assert.deepEqual([w.type, w.id, Math.round(w.lat * 1000) / 1000, Math.round(w.lng * 1000) / 1000], ['w', 1001, 43.665, -79.33]);
  const r = parseOsmLine(area('r77', 'suburb', { type: 'MultiPolygon', coordinates: [sq.coordinates, [[[0, 0], [1, 1], [0, 0]]]] }))!;
  assert.deepEqual([r.type, r.id], ['r', 77], 'the larger ring of a multipolygon');
  assert.deepEqual([parseOsmLine(area('a2002', 'quarter', sq))!.type, parseOsmLine(area('a2002', 'quarter', sq))!.id], ['w', 1001], "osmium's area id of a way");
  assert.deepEqual([parseOsmLine(area('a155', 'quarter', sq))!.type, parseOsmLine(area('a155', 'quarter', sq))!.id], ['r', 77], "osmium's area id of a relation");
  assert.equal(parseOsmLine(area('w5', 'city', sq)), null, 'cities stay nodes only');
  const ids = [osmSrcId({ id: 1001, type: 'n' }), osmSrcId({ id: 1001, type: 'w' }), osmSrcId({ id: 1001, type: 'r' })];
  assert.equal(new Set(ids).size, 3);
  assert.ok(ids.every((x) => x < 0 && x > -1e13), 'never in the Census range (minus 10^13 and beyond)');
  // an area with the name of a node close by is the same place
  const node = parseOsmLine(JSON.stringify({ type: 'Feature', id: 'n9', geometry: { type: 'Point', coordinates: [-79.331, 43.664] }, properties: { name: 'Leslieville', place: 'neighbourhood' } }))!;
  const out = buildPlaces({ geonames: [{ id: 6167865, name: 'Toronto', lat: 43.7, lng: -79.42, fclass: 'P', fcode: 'PPLA', cc: 'CA', admin1: '08', admin2: '3520', population: 2_600_000 }],
    osm: [node, w], regions: ['CA-ON'], fixture: true });
  assert.equal(out.places.filter((p) => p.name === 'Leslieville').length, 1);
  assert.equal(ringCentre({ type: 'Point', coordinates: [0, 0] }), null);
});
