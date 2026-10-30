import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cmsSignedData, iconPng, issuerAndSerial, passJson, readTlv, signedAttrs, tlv } from './pkpass.ts';

const facts = { number: 'CC-10482', car: '2023 Mercedes-Benz C 300', pickup: '2026-11-05T15:00:00.000Z', ret: '2026-11-08T15:00:00.000Z', place: '100 Queen St W, Toronto', returnPlace: null, phone: '(647) 555-0100', site: 'https://carmacars.ca' };

test('the pass carries the booking number, car, times and address', () => {
  const p = passJson(facts, { passTypeId: 'pass.ca.carmacars.booking', teamId: 'ABCDE12345' }) as { serialNumber: string; barcodes: Array<{ message: string }>; eventTicket: Record<string, Array<{ value: string }>> };
  assert.equal(p.serialNumber, 'CC-10482');
  assert.equal(p.eventTicket.primaryFields![0]!.value, facts.car);
  assert.equal(p.eventTicket.secondaryFields![0]!.value, facts.pickup);
  assert.ok(p.eventTicket.backFields!.some((f) => f.value === facts.place));
  assert.equal(p.barcodes[0]!.message, 'CC-10482');
});
test('the icon is a PNG of the asked size', () => {
  const png = iconPng(29);
  assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  assert.equal((png[16]! << 24) | (png[17]! << 16) | (png[18]! << 8) | png[19]!, 29);
});
test('a certificate gives its issuer and serial; the CMS wraps signer, chain and signature', () => {
  // a fake certificate: SEQ { SEQ { [0] { INT 2 }, INT 0x2a, SEQ { NULL }, SEQ issuer } }
  const issuer = tlv(0x30, tlv(0x31, tlv(0x30, tlv(0x06, new Uint8Array([85, 4, 3])), tlv(0x0c, new TextEncoder().encode('WWDR')))));
  const cert = tlv(0x30, tlv(0x30, tlv(0xa0, tlv(0x02, new Uint8Array([2]))), tlv(0x02, new Uint8Array([42])), tlv(0x30, new Uint8Array([5, 0])), issuer));
  const ias = issuerAndSerial(cert);
  const inner = readTlv(ias, 0);
  assert.equal(ias[inner.content], 0x30);
  assert.ok(Buffer.from(ias).includes(Buffer.from([2, 1, 42])));
  const attrs = signedAttrs(new Uint8Array(32), new Date('2026-11-01T00:00:00Z'));
  assert.equal(attrs[0], 0x31);
  const cms = cmsSignedData({ signerCert: cert, chain: [cert], digest: new Uint8Array(32), at: new Date('2026-11-01T00:00:00Z'), signature: new Uint8Array(256) });
  assert.equal(cms[0], 0x30);
  assert.equal(readTlv(cms, 0).end, cms.length);
});
