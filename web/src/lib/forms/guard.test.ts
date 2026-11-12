import test from 'node:test';
import assert from 'node:assert/strict';
import { cleanLabel, fieldsNamedIn, humanName, problemLine, problemSig, summaryTitle, validityMessage } from './guard.ts';

test('an empty required field says what to do for its kind', () => {
  assert.equal(validityMessage({ valueMissing: true }, { kind: 'text' }), 'Fill this in.');
  assert.equal(validityMessage({ valueMissing: true }, { kind: 'checkbox' }), 'Tick this box to continue.');
  assert.equal(validityMessage({ valueMissing: true }, { kind: 'select' }), 'Choose an option.');
  assert.equal(validityMessage({ valueMissing: true }, { kind: 'radio' }), 'Choose one.');
});

test('a wrong value says why', () => {
  assert.match(validityMessage({ typeMismatch: true }, { kind: 'email' }), /valid email/);
  assert.match(validityMessage({ tooShort: true }, { kind: 'text', minLength: 8 }), /at least 8/);
  assert.equal(validityMessage({ rangeUnderflow: true }, { kind: 'number', min: '18' }), 'Enter 18 or more.');
  assert.equal(validityMessage({ rangeOverflow: true }, { kind: 'number', max: '99' }), 'Enter 99 or less.');
  assert.equal(validityMessage({ patternMismatch: true }, { kind: 'text', title: 'Six digits.' }), 'Check the format: Six digits.');
  assert.equal(validityMessage({ customError: true }, { kind: 'text', message: 'Too old' }), 'Too old');
  assert.equal(validityMessage({}, { kind: 'text' }), 'Check this field.');
});

test('labels and names are read as words', () => {
  assert.equal(cleanLabel("  Driver's  licence number *"), "Driver's licence number");
  assert.equal(cleanLabel('Mobile number (optional)'), 'Mobile number');
  assert.equal(cleanLabel('Booking number optional'), 'Booking number');
  assert.equal(humanName('licence_number'), 'licence number');
  assert.equal(humanName('homeAddress'), 'home address');
  assert.equal(humanName('vehicles[0]-plate'), 'vehicles plate');
});

test('a server message names the field whose label it contains', () => {
  const fields = [{ id: 'a', label: "Driver's licence number", name: 'licence_number' }, { id: 'b', label: 'Home address', name: 'home_address' }, { id: 'c', label: 'Address' }, { id: 'd', label: 'Age' }];
  assert.deepEqual(fieldsNamedIn('Driver’s licence number is required.', fields), ['a']);
  assert.deepEqual(fieldsNamedIn('Write your licence number as it is on the card', fields), ['a']);
  // the longer label wins over the shorter one inside it
  assert.deepEqual(fieldsNamedIn('Home address is missing', fields), ['b']);
  assert.deepEqual(fieldsNamedIn('Address is missing', fields), ['c']);
  // a label under four letters never matches; nothing named means no field
  assert.deepEqual(fieldsNamedIn('Age must be 18 or more', fields), []);
  assert.deepEqual(fieldsNamedIn('Something went wrong, try again', fields), []);
  // whole words only
  assert.deepEqual(fieldsNamedIn('The addresses differ', [{ id: 'c', label: 'Address' }]), []);
});

test('the summary words', () => {
  assert.equal(summaryTitle(1), 'Fix 1 thing to continue');
  assert.equal(summaryTitle(3), 'Fix these 3 things to continue');
  assert.equal(problemLine({ id: 'x', label: 'Email', message: 'Fill this in.' }), 'Email: Fill this in.');
  assert.equal(problemLine({ id: 'x', label: '', message: 'Fill this in.' }), 'Fill this in.');
  assert.notEqual(problemSig([{ id: 'x', label: 'A', message: 'm' }]), problemSig([{ id: 'x', label: 'A', message: 'n' }]));
});
