import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { countPeople, filterOf, filtersFor, goodFix, initials, personLabel, stateLine, visiblePeople, type MapPerson, type PeopleView } from './people.ts';

// The live map's people layer (migration 3350, release 48 part MAP).
const p = (o: Partial<MapPerson> = {}): MapPerson => ({ id: 'a', kind: 'staff', role: 'fleet', name: 'Maya Chen', lat: 43.65, lng: -79.38, at: '2026-11-20T15:00:00Z', reason: 'shift', source: 'web', ...o });

describe('people on the live map', () => {
  it('initials', () => {
    assert.equal(initials('Maya Chen'), 'MC');
    assert.equal(initials('  ali  '), 'A');
    assert.equal(initials('Jean-Baptiste de la Fontaine-Rousseau'), 'JF');
    assert.equal(initials(''), '?');
  });
  it('labels say who, the role and why', () => {
    assert.equal(personLabel(p()), 'Maya Chen, Fleet, on shift');
    assert.equal(personLabel(p({ role: 'field', reason: 'job', job: { id: 'j', kind: 'handover', status: 'in_progress' } })), 'Maya Chen, Field staff, on a job (hand-over)');
    assert.equal(personLabel(p({ kind: 'renter', role: 'renter', reason: 'pickup', booking_number: 'MP-1' })), 'Maya Chen, Renter, at a pickup (MP-1)');
  });
  it('filters by role and drops bad positions', () => {
    const v: PeopleView = { scope: 'all', people: [p(), p({ id: 'b', role: 'field' }), p({ id: 'c', kind: 'renter', role: 'renter' }), p({ id: 'd', lat: Number.NaN })] };
    assert.deepEqual(visiblePeople(v, new Set()).map((x) => x.id), ['a', 'b', 'c']);
    assert.deepEqual(visiblePeople(v, new Set(['field', 'staff'])).map((x) => x.id), ['c']);
    assert.deepEqual(countPeople(v), { staff: 2, field: 1, renter: 1, owner: 0 });
    assert.equal(filterOf('admin'), 'staff');
    assert.equal(visiblePeople(null, new Set()).length, 0);
  });
  it('the filters follow the scope the database gave', () => {
    assert.equal(filtersFor('all').length, 4);
    assert.deepEqual(filtersFor('renters').map((f) => f.key), ['renter']);
    assert.equal(filtersFor('none').length, 0);
  });
  it('a fix is sent only when fresh, in range and accurate enough', () => {
    const now = Date.parse('2026-11-20T15:00:00Z');
    assert.equal(goodFix({ lat: 43.6, lng: -79.4, accuracy: 20, at: now - 5000 }, now), true);
    assert.equal(goodFix({ lat: 43.6, lng: -79.4, accuracy: 20, at: now - 300_000 }, now), false);
    assert.equal(goodFix({ lat: 95, lng: -79.4, accuracy: 20, at: now }, now), false);
    assert.equal(goodFix({ lat: 43.6, lng: -79.4, accuracy: 9000, at: now }, now), false);
  });
  it('the state line is plain words for every state', () => {
    for (const why of ['policy', 'job', 'shift', 'off_duty', 'off', 'pickup', 'return', 'no_booking', 'view_as', 'none']) assert.ok(stateLine({ share: false, kind: null, why }).length > 5);
    assert.match(stateLine({ share: false, kind: 'staff', why: 'off_duty' }), /off duty/);
  });
});
