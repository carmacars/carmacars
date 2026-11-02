import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cameraOptions, cancelled, photoFile, photoModeFor, type InputFacts } from './camera.ts';

// The store app's camera for the site's photo fields (migration 0390): which inputs it takes over, how, and the photo
// coming back as a file.
const input = (o: Partial<InputFacts>): InputFacts => ({ type: 'file', accept: '', capture: null, multiple: false, disabled: false, optOut: false, ...o });

test('camera fields open the native camera; the selfie the front camera', () => {
  assert.deepEqual(photoModeFor(input({ accept: 'image/*', capture: 'environment' })), { source: 'CAMERA', direction: 'REAR' });
  assert.deepEqual(photoModeFor(input({ accept: 'image/*', capture: 'user' })), { source: 'CAMERA', direction: 'FRONT' });
  // the licence: a camera button whose accept also lists PDF (its "Choose a file" sibling takes the PDF)
  assert.deepEqual(photoModeFor(input({ accept: 'image/*,.jpg,.jpeg,.png,.heic,.heif,.webp,application/pdf,.pdf', capture: 'environment' })), { source: 'CAMERA', direction: 'REAR' });
});

test('an image-only field offers the camera or the library; others keep the phone\'s chooser', () => {
  assert.deepEqual(photoModeFor(input({ accept: 'image/jpeg,image/png' })), { source: 'PROMPT', direction: 'REAR' });
  for (const o of [{ accept: 'application/pdf' }, { accept: 'image/*,application/pdf' }, { accept: '' }, { accept: 'image/*', multiple: true },
    { accept: 'image/*', capture: 'environment', multiple: true }, { accept: 'image/*', disabled: true }, { accept: 'image/*', optOut: true }, { type: 'text', accept: 'image/*' }, { accept: '.csv,text/csv' }])
    assert.equal(photoModeFor(input(o)), null, JSON.stringify(o));
});

test('the plugin options: a JPEG up to 2400 px, upright, not saved to the library', () => {
  const o = cameraOptions({ source: 'CAMERA', direction: 'FRONT' });
  assert.equal(o.resultType, 'base64'); assert.equal(o.width, 2400); assert.equal(o.correctOrientation, true); assert.equal(o.saveToGallery, false); assert.equal(o.direction, 'FRONT');
});

test('the photo comes back as a file for the input', async () => {
  const f = photoFile(btoa('\xff\xd8\xff\xe0jpeg'), 'jpeg', 1_700_000_000_000);
  assert.equal(f.name, 'photo-1700000000000.jpg'); assert.equal(f.type, 'image/jpeg'); assert.equal(f.size, 8);
  assert.equal(new Uint8Array(await f.arrayBuffer())[0], 0xff);
  assert.equal(photoFile(btoa('png'), 'png').type, 'image/png');
  assert.equal(photoFile('data:image/jpeg;base64,' + btoa('x'), 'jpeg').size, 1);
});

test('closing the camera is not an error', () => {
  assert.equal(cancelled(new Error('User cancelled photos app')), true);
  assert.equal(cancelled(new Error('No image picked')), true);
  assert.equal(cancelled(new Error('Unable to access camera')), false);
});
