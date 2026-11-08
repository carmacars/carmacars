// The one Onboarding checklist (r34, 0823): the state of each step, who it waits on, why it is blocked, and exactly one
// next action for the person looking.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { baseFor, carSteps, ownerStep, whoText, type ChecklistRow, type Overview, type OverviewCar } from './steps.ts';
import { parseVinList, vinProblem, VIN_LIST_MAX } from './vin-list.ts';

const row = (code: string, status: ChecklistRow['status'] = 'open', waits_on: ChecklistRow['waits_on'] = 'carmacars'): ChecklistRow => ({ code, label: code, status, waits_on, owner_action: null, staff_action: null });
const ROWS = (over: Partial<Record<string, ChecklistRow['status']>> = {}): ChecklistRow[] => [
  row('owner_details', over.owner_details ?? 'done', 'owner'), row('documents', over.documents ?? 'done', 'owner'), row('government_forms', over.government_forms ?? 'open'),
  row('signatures', over.signatures ?? 'open', 'owner'), row('witnessed_forms', over.witnessed_forms ?? 'open', 'owner'), row('upfront_payment', over.upfront_payment ?? 'open', 'owner'),
  row('registry_visit', over.registry_visit ?? 'open'), row('tracker_install', 'open'), row('insurer_confirmation', 'open'), row('photos', 'open'), row('listing', 'open')];
const car = (over: Partial<OverviewCar> = {}): OverviewCar => ({
  vehicle_id: 'v1', name: '2021 Hyundai Sonata N Line', plate: 'TEST01', status: 'onboarding', onboarding_status: 'terms_set', mode: 'managed', application_id: 'a1', application_number: 'OA-1',
  terms_pending: false, schedule: { number: 'VS-1', signed: false }, checklist: ROWS(),
  photos: { permit: 1, waiting: 0, rejected: 0, approved: 1, total: 1, note: null }, forms: { due: true, needed: 2, made: 2, drafts: 0, signed: 0, missing: [] }, upfront: null, ...over });
const ov = (viewer: Overview['viewer'], c: OverviewCar = car(), missing: string[] = []): Overview => ({ viewer, owner: { id: 'o1', name: 'Pat Example', type: 'individual', fleet_supplier: false, missing, has_account: true }, trackers: false, cars: [c] });
const step = (o: Overview, code: string) => carSteps(o.cars[0]!, o).steps.find((s) => s.code === code)!;

test('a car waiting for its terms: the Admin approves them; the steps after them are blocked with the reason', () => {
  const c = car({ onboarding_status: 'intake', schedule: null, forms: { due: false, needed: 0, made: 0, drafts: 0, signed: 0, missing: [] } });
  const a = ov('admin', c);
  assert.deepEqual([step(a, 'terms').state, step(a, 'terms').waiting, step(a, 'terms').action?.href], ['waiting', 'Waiting on an Admin', '/admin/applications/a1']);
  assert.equal(step(a, 'signatures').state, 'blocked');
  assert.equal(step(a, 'signatures').why, 'First: terms approved.');
  assert.equal(step(a, 'government_forms').why, 'Made by themselves once the terms are approved.');
  // the owner and staff see who it waits on, and nothing to press
  assert.deepEqual([step(ov('owner', c), 'terms').waiting, step(ov('owner', c), 'terms').action], ['Waiting on CarmaCars', null]);
  assert.equal(step(ov('staff', c), 'terms').action, null);
});

test('exactly one action per step, the viewer\'s own, and none on a done step (except where the forms are)', () => {
  for (const viewer of ['owner', 'staff', 'admin'] as const) {
    const s = carSteps(car(), ov(viewer));
    for (const x of s.steps) {
      if (x.state === 'done' && x.code !== 'government_forms') assert.equal(x.action, null, `${viewer} ${x.code}`);
      if (x.action) assert.ok(x.action.label.length > 0 && !!x.action.href, `${viewer} ${x.code}`);
    }
  }
  assert.deepEqual(step(ov('owner'), 'signatures').action, { label: 'Check and sign', href: '/owner/sign' });
  assert.equal(step(ov('staff'), 'signatures').action?.href, '/staff/owners/o1#send-link');
  assert.equal(step(ov('admin'), 'upfront_payment').action?.href, '/admin/owners/o1#ad-up');
  assert.equal(step(ov('staff'), 'upfront_payment').action, null);
});

test('photos: missing, waiting for the check, not accepted', () => {
  const none = car({ photos: { permit: 0, waiting: 0, rejected: 0, approved: 0, total: 0, note: null } });
  assert.deepEqual([step(ov('owner', none), 'documents').waiting, step(ov('owner', none), 'documents').action?.label], ['Waiting on you', 'Upload the ownership permit']);
  const waiting = car({ checklist: ROWS({ documents: 'done' }), photos: { permit: 1, waiting: 1, rejected: 0, approved: 0, total: 1, note: null } });
  assert.deepEqual([step(ov('staff', waiting), 'documents').state, step(ov('staff', waiting), 'documents').action?.label], ['waiting', 'Check the photos']);
  assert.equal(step(ov('owner', waiting), 'documents').action, null);
  const rejected = car({ photos: { permit: 1, waiting: 0, rejected: 1, approved: 0, total: 1, note: 'Blurry' } });
  assert.equal(step(ov('owner', rejected), 'documents').why, 'A photo was not accepted: Blurry');
  assert.equal(step(ov('owner', rejected), 'documents').action?.label, 'Upload a new photo');
});

test('government forms: made by themselves; a missing value blocks them with what is missing', () => {
  const drafts = car({ forms: { due: true, needed: 2, made: 2, drafts: 2, signed: 0, missing: ['Registrant identification number'] } });
  assert.deepEqual([step(ov('owner', drafts, ['City']), 'government_forms').state, step(ov('owner', drafts, ['City']), 'government_forms').why], ['blocked', 'Missing: Registrant identification number.']);
  assert.equal(step(ov('owner', drafts, ['City']), 'government_forms').action?.href, '/owner/profile');
  assert.equal(step(ov('admin', drafts), 'government_forms').action?.href, '/admin/owners/o1#gov-forms');
  const ready = car({ checklist: ROWS({ government_forms: 'done' }) });
  assert.equal(step(ov('owner', ready), 'government_forms').state, 'done');
  assert.equal(step(ov('owner', ready), 'government_forms').action?.href, '/owner/documents#ow-forms');
  const none = car({ forms: { due: true, needed: 0, made: 0, drafts: 0, signed: 0, missing: [] }, checklist: ROWS({ government_forms: 'not_applicable' }) });
  assert.equal(step(ov('owner', none), 'government_forms').state, 'not_needed');
});

test('the owner\'s details, once; the counts and the next step', () => {
  assert.equal(ownerStep(ov('owner', car(), ['City'])).why, 'Missing: City.');
  assert.equal(ownerStep(ov('admin', car(), ['City'])).action?.href, '/admin/owners/o1#send-link');
  assert.equal(ownerStep(ov('owner')).state, 'done');
  const s = carSteps(car(), ov('owner'));
  assert.ok(!s.steps.some((x) => x.code === 'owner_details' || x.code === 'tracker_install'));
  assert.equal(s.next?.code, 'signatures');
  assert.ok(s.done >= 2 && s.total > s.done);
  assert.equal(whoText('third_party', 'owner'), 'Waiting on another office (the registry or the insurer)');
  assert.equal(baseFor('staff', 'o1').carHref('v1'), '/staff/vehicles/v1');
});

test('a VIN list: pasted, a CSV with a VIN column, typos kept to report, at most 50', () => {
  assert.deepEqual(parseVinList('1hgcm82633a004352\n 1HGCM82693A200019, 2T1BURHE0JC000000').vins, ['1HGCM82633A004352', '1HGCM82693A200019', '2T1BURHE0JC000000']);
  assert.deepEqual(parseVinList('Year,Make,VIN,Price\n2021,Toyota,"1HGCM82633A004352",25000\n2022,Honda,1HGCM8263,1').vins, ['1HGCM82633A004352']);
  assert.deepEqual(parseVinList('Our cars: 1HGCM82633A00435 and 2021 Civic').vins, ['1HGCM82633A00435']);
  const many = Array.from({ length: 52 }, () => '1HGCM82633A004352').join('\n');
  assert.deepEqual([parseVinList(many).vins.length, parseVinList(many).extra], [VIN_LIST_MAX, 2]);
  assert.equal(vinProblem('1HGCM82633A004352'), null);
  assert.match(vinProblem('1HGCM82633A004353') ?? '', /check digit/);
  assert.match(vinProblem('1HGCM82633A00435') ?? '', /17 letters/);
});
