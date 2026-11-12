import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { contactOptional, dobOptional, renterProblem } from './renter-contact.ts';

const insurerOff = { paidBy: 'insurer', blocks: false };
const name = { full_name: 'Nia Example', date_of_birth: '1980-01-01' };

describe('contactOptional', () => {
  it('is true only for an insurer-billed rental that does not block the calendar', () => {
    assert.equal(contactOptional(insurerOff), true);
    assert.equal(contactOptional({ paidBy: 'insurer', blocks: true }), false);
    assert.equal(contactOptional({ paidBy: 'e_transfer', blocks: false }), false);
    assert.equal(contactOptional({ paidBy: 'link', blocks: false }), false);
    assert.equal(contactOptional({ paidBy: 'insurer', blocks: false, placeholder: true }), false);
  });
});

describe('renterProblem', () => {
  it('insurer + off the calendar: a name and a date of birth are enough', () => {
    assert.equal(renterProblem(name, insurerOff), null);
  });
  it('insurer + off the calendar: a typed email must still look like one', () => {
    assert.match(renterProblem({ ...name, email: 'nope' }, insurerOff) ?? '', /does not look right/);
    assert.equal(renterProblem({ ...name, email: 'nia@example.test' }, insurerOff), null);
  });
  it('the name is always needed; the date of birth only when the rent is not billed to an insurer', () => {
    assert.match(renterProblem({ date_of_birth: '1980-01-01' }, insurerOff) ?? '', /full legal name/);
    assert.match(renterProblem({ full_name: 'Nia Example' }, { paidBy: 'e_transfer', blocks: true }) ?? '', /date of birth/);
    assert.match(renterProblem({ full_name: 'Nia Example', email: 'nia@example.test', mobile: '4165550100' }, { paidBy: 'link', blocks: false }) ?? '', /date of birth/);
  });
  it('insurer-billed: no date of birth needed, on or off the calendar, and the contact rules are unchanged', () => {
    assert.equal(dobOptional({ paidBy: 'insurer', blocks: true }), true);
    assert.equal(dobOptional({ paidBy: 'cash', blocks: false }), false);
    assert.equal(renterProblem({ full_name: 'Nia Example' }, insurerOff), null);
    assert.match(renterProblem({ full_name: 'Nia Example' }, { paidBy: 'insurer', blocks: true }) ?? '', /email/);
    assert.equal(renterProblem({ full_name: 'Nia Example', email: 'nia@example.test', mobile: '4165550100' }, { paidBy: 'insurer', blocks: true }), null);
  });
  it('every other case still needs the email and the phone', () => {
    for (const c of [{ paidBy: 'insurer', blocks: true }, { paidBy: 'e_transfer', blocks: false }, { paidBy: 'link', blocks: true }]) {
      assert.match(renterProblem(name, c) ?? '', /email/);
      assert.match(renterProblem({ ...name, email: 'nia@example.test' }, c) ?? '', /phone/);
      assert.equal(renterProblem({ ...name, email: 'nia@example.test', mobile: '4165550100' }, c), null);
    }
  });
});
