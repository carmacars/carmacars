// The seo-data import's parsers (release 35, part M): every row keeps its source; missing values are left out.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chunks, curatedSpecRows, fuelEconomyRows, gtfsStops, mpgToL100, osmHotels, parseCsv, ratingRows, recallRow } from './seo-data.ts';

const AT = '2026-11-08T00:00:00.000Z';
const GO = { agency: 'GO Transit', url: 'https://example.test/go.zip', licence: 'Example Open Data Licence', page: 'https://example.test/open-data' };

test('CSV: quotes, doubled quotes, CRLF and a byte order mark', () => {
  const rows = parseCsv('﻿stop_id,stop_name,stop_lat\r\n"1","Union Station, ""GO""",43.645\r\n2,Plain,43.7\r\n');
  assert.deepEqual(rows, [{ stop_id: '1', stop_name: 'Union Station, "GO"', stop_lat: '43.645' }, { stop_id: '2', stop_name: 'Plain', stop_lat: '43.7' }]);
});

test('GTFS stops: stations and stops kept with the feed and its licence, platforms and bad coordinates left out', () => {
  const rows = gtfsStops(GO, [
    { stop_id: 'UN', stop_name: 'Union Station', stop_lat: '43.645', stop_lon: '-79.380', location_type: '1' },
    { stop_id: 'UN1', stop_name: 'Union Station Platform 1', stop_lat: '43.645', stop_lon: '-79.380', location_type: '0', parent_station: 'UN' },
    { stop_id: 'X', stop_name: 'Somewhere', stop_lat: '0', stop_lon: '0' },
    { stop_id: '123', stop_name: 'Hwy 7 at Main St', stop_lat: '43.8', stop_lon: '-79.3', location_type: '0' },
    { stop_id: 'E', stop_name: 'Entrance', stop_lat: '43.8', stop_lon: '-79.3', location_type: '2' }
  ], AT);
  assert.deepEqual(rows.map((r) => [r.ref, r.kind]), [['UN', 'go_station'], ['123', 'bus_stop']]);
  assert.equal(rows[0]!.source_url, 'https://example.test/open-data');
  assert.equal(rows[0]!.attribution, 'Stops: GO Transit GTFS (Example Open Data Licence)');
  assert.equal(rows[0]!.fetched_at, AT);
  const ttc = gtfsStops({ ...GO, agency: 'TTC' }, [{ stop_id: '1', stop_name: 'Bloor-Yonge Station', stop_lat: '43.67', stop_lon: '-79.38', location_type: '1' }], AT);
  assert.equal(ttc[0]!.kind, 'subway_station');
});

test('OpenStreetMap hotels: named hotels and motels only, with the ODbL attribution', () => {
  const rows = osmHotels({ elements: [
    { type: 'node', id: 1, lat: 43.6, lon: -79.6, tags: { tourism: 'hotel', name: 'Example Hotel' } },
    { type: 'way', id: 2, center: { lat: 43.7, lon: -79.5 }, tags: { tourism: 'motel', name: 'Example Motel' } },
    { type: 'node', id: 3, lat: 43.6, lon: -79.6, tags: { tourism: 'hotel' } },
    { type: 'node', id: 4, lat: 43.6, lon: -79.6, tags: { tourism: 'guest_house', name: 'A house' } }
  ] }, AT);
  assert.deepEqual(rows.map((r) => r.ref), ['node/1', 'way/2']);
  assert.equal(rows[0]!.attribution, 'Hotels: © OpenStreetMap contributors (ODbL)');
  assert.equal(rows[1]!.source_url, 'https://www.openstreetmap.org/way/2');
});

test('fueleconomy.gov and NHTSA: converted figures with their source; a missing value is left out', () => {
  assert.equal(mpgToL100(30), 7.8);
  const t = { make: 'Toyota', model: 'Corolla', year: 2024 };
  const rows = fuelEconomyRows({ city08: 32, highway08: 41, comb08: 35, fuelType: 'Regular Gasoline', drive: 'Front-Wheel Drive', trany: 'Automatic (AV-S10)', displ: 2.0, cylinders: 4, model: 'Corolla' }, t, AT);
  const by = Object.fromEntries(rows.map((r) => [r.field, r.value]));
  assert.equal(by.fuel_city_l100, '7.4');
  assert.equal(by.fuel_highway_l100, '5.7');
  assert.equal(by.engine, '2 L, 4 cylinders');
  assert.ok(rows.every((r) => r.source === 'fueleconomy_gov' && r.source_url.startsWith('https://www.fueleconomy.gov/')));
  assert.ok(!fuelEconomyRows({ city08: 0, fuelType: '' }, t, AT).some((r) => r.field === 'fuel_city_l100' || r.field === 'fuel_type'));
  assert.equal(recallRow({ Count: 3 }, t, AT)!.value, '3');
  assert.equal(recallRow({}, t, AT), null);
  assert.deepEqual(ratingRows({ OverallRating: '5', RolloverRating: 'Not Rated' }, t, AT).map((r) => [r.field, r.value]), [['safety_overall', '5']]);
});

test('a curated spec CSV: rows without a value, a known field or an https source are refused', () => {
  const r = curatedSpecRows([
    { make: 'Toyota', model: 'Corolla', year: '2024', trim: 'SE', field: 'tire_size', value: '225/40R18', source: 'oem', source_url: 'https://example.test/spec' },
    { make: 'Toyota', model: 'Corolla', year: '2024', trim: '', field: 'paint_colour', value: 'Example Red', code: '3T3', source: 'oem', source_url: 'https://example.test/colours' },
    { make: 'Toyota', model: 'Corolla', year: '2024', field: 'hp', value: '', source: 'oem', source_url: 'https://example.test/spec' },
    { make: 'Toyota', model: 'Corolla', year: '2024', field: 'hp', value: '169', source: 'oem', source_url: 'http://example.test/spec' },
    { make: 'Toyota', model: 'Corolla', year: '2024', field: 'made_up', value: '1', source: 'oem', source_url: 'https://example.test/spec' },
    { make: 'Toyota', model: 'Corolla', year: '2024', field: 'hp', value: '169', source: 'a blog', source_url: 'https://example.test/spec' }
  ], AT);
  assert.equal(r.rows.length, 2);
  assert.equal(r.rejected, 4);
  assert.equal(r.rows[1]!.code, '3T3');
  assert.equal(chunks([1, 2, 3, 4, 5], 2).length, 3);
});
