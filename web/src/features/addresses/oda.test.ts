import { test } from 'node:test';
import assert from 'node:assert/strict';
import { copyLine, csvLine, headerIndex, odaRow, odaUrl, titleCase } from './oda.ts';

const H = headerIndex(csvLine('\uFEFFlatitude,longitude,source_id,id,group_id,street_no,street,str_name,str_type,str_dir,unit,city,postal_code,full_addr,city_pcs,str_name_pcs,str_type_pcs,str_dir_pcs,csduid,csdname,pruid,provider'));

test('csv: quotes and doubled quotes', () => {
  assert.deepEqual(csvLine('a,"b, c","d ""e"""'), ['a', 'b, c', 'd "e"']);
});

test('an ODA row: street, number, unit, city, postal code, point', () => {
  const r = odaRow(csvLine('43.6426,-79.3871,x,1,,65,FRONT ST W,FRONT,ST,W,4,TORONTO,m5j1e6,,,,,,3520005,Toronto,35,Toronto'), H, 'ON');
  assert.deepEqual(r, { province: 'ON', num: '65', street: 'Front St W', unit: '4', city: 'Toronto', postal: 'M5J 1E6', lat: 43.6426, lng: -79.3871 });
  assert.equal(copyLine(r!), 'ON,65,Front St W,4,Toronto,M5J 1E6,43.6426,-79.3871\n');
});

test('an ODA row without the full street: built from its parts; no city: the census subdivision; a bad postal code is dropped', () => {
  const r = odaRow(csvLine('45.5,-73.6,x,1,,12,,DE LA GARE,RUE,,,,H2X,,,,,,2466023,MONTRÉAL,24,'), H, 'QC');
  assert.equal(r?.street, 'De la Gare Rue');
  assert.equal(r?.city, 'Montréal');
  assert.equal(r?.postal, null);
  assert.equal(r?.province, 'QC');
});

test('no street: not kept; a point outside Canada is not kept', () => {
  assert.equal(odaRow(csvLine('43,-79,x,1,,5,,,,,,,,,,,,,,,35,'), H, 'ON'), null);
  assert.equal(odaRow(csvLine('10,10,x,1,,5,MAIN ST,,,,,X,,,,,,,,,35,'), H, 'ON')?.lat, null);
});

test('a field with a comma is quoted for COPY', () => {
  assert.match(copyLine({ province: 'ON', num: '1', street: 'A, B', unit: null, city: null, postal: null, lat: null, lng: null }), /^ON,1,"A, B",,,,,\n$/);
});

test('title case keeps small words and hyphens', () => {
  assert.equal(titleCase("CHEMIN DE L'ÉGLISE"), "Chemin de L'Église");
  assert.equal(titleCase('SAINT-JEAN'), 'Saint-Jean');
  assert.match(odaUrl('ON'), /ODA_ON_v1\.zip$/);
});
