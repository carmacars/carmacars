import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { build, buildData, parseRelease, OUT } from '../../scripts/whats-new.mjs';
import { latestFor, pickPopup, prettyDate, releaseOrder, showFor, type WnData } from './whats-new.ts';

const note = (o: { release?: string; date?: string; seq?: number; body: string }) =>
  `---\nrelease: ${o.release ?? 'r90'}\ntitle: Release 90\ndate: ${o.date ?? '2031-01-02'}\n${o.seq ? `seq: ${o.seq}\n` : ''}summary: A **short** summary.\nchanges:\n  - 2031-01-02-x.md\n---\n${o.body}`;

test('generator: only the "For <portal>" sections are read, in plain words', () => {
  const r = parseRelease(note({ body: '## Staff tools\n\n- Not for the pop-up\n\n## For staff\n\n- Sales gets a **To-do** for `every` request\n- A [link](https://example.test) is plain text\n\n## For renters\n\n- Pay with the card that covers the rental\n' }), 'r90.md');
  assert.deepEqual(r, {
    release: 'r90', date: '2031-01-02', seq: 0, summary: 'A short summary.',
    sections: { staff: ['Sales gets a To-do for every request', 'A link is plain text'], renters: ['Pay with the card that covers the rental'] }
  });
});

test('generator: a pending release, or one with no portal section, is left out', () => {
  assert.equal(parseRelease(note({ date: 'pending', body: '## For staff\n\n- Soon\n' })), null);
  assert.equal(parseRelease(note({ body: '## Staff tools\n\n- Only the investor note\n' })), null);
  assert.equal(parseRelease(note({ body: '## For staff\n\n' })), null);
});

test('generator: a malformed note names its file; long dashes are refused', () => {
  assert.throws(() => parseRelease('no front matter', 'r1.md'), /r1\.md: no front matter/);
  assert.throws(() => parseRelease(note({ date: 'soonish', body: '## For staff\n\n- x\n' }), 'r2.md'), /r2\.md: the date is/);
  assert.throws(() => parseRelease(note({ release: 'R 3', body: '## For staff\n\n- x\n' }), 'r3.md'), /not a short plain id/);
  assert.throws(() => parseRelease(note({ body: '## For staff\n\n- one — two\n' }), 'r4.md'), /no long dashes/);
  assert.throws(() => parseRelease(note({ body: '## For staff\n\n- one – two\n' }), 'r4.md'), /no long dashes/);
});

test('generator: a folder is read in release order and the file name must match the release', () => {
  const dir = mkdtempSync(join(tmpdir(), 'wn-'));
  writeFileSync(join(dir, 'r91.md'), note({ release: 'r91', date: '2031-02-01', body: '## For owners\n\n- b\n' }));
  writeFileSync(join(dir, 'r90.md'), note({ release: 'r90', date: '2031-01-02', body: '## For owners\n\n- a\n' }));
  writeFileSync(join(dir, 'r92.md'), note({ release: 'r92', date: 'pending', body: '## For owners\n\n- c\n' }));
  writeFileSync(join(dir, 'hotfix-2031-01-01.md'), 'not a release file');
  assert.deepEqual(Object.keys(buildData(dir).releases), ['r90', 'r91']);
  assert.ok(build(dir).endsWith('}\n'));
  writeFileSync(join(dir, 'r93.md'), note({ release: 'r94', body: '## For owners\n\n- d\n' }));
  assert.throws(() => buildData(dir), /must match the file name/);
});

test('generator: the committed whats-new.json is what the release notes build to', () => {
  assert.ok(existsSync(OUT), 'run node scripts/whats-new.mjs');
  assert.equal(readFileSync(OUT, 'utf8'), build(), 'whats-new.json is out of date: run node scripts/whats-new.mjs');
});

const data: WnData = {
  releases: {
    r40: { date: '2031-01-01', seq: 0, summary: 's40', sections: { staff: ['a'], owners: ['o40'] } },
    r41: { date: '2031-02-01', seq: 0, summary: 's41', sections: { renters: ['r41'], owners: ['o41'] } },
    r41b: { date: '2031-02-01', seq: 1, summary: 's41b', sections: { staff: ['b'] } },
    r42: { date: 'pending', seq: 0, summary: 's42', sections: { staff: ['never'] } }
  }
};

test('selection: newest first by date, then seq', () => {
  assert.deepEqual(releaseOrder(data).filter((r) => r !== 'r42'), ['r41b', 'r41', 'r40']);
});

test('selection: a portal sees its own words, and an undated release never shows', () => {
  assert.deepEqual(showFor(data, 'r41', 'renter')?.items, ['r41']);
  assert.equal(showFor(data, 'r41', 'staff'), null);
  assert.equal(showFor(data, 'r42', 'staff'), null);
  assert.equal(latestFor(data, 'staff')?.release, 'r41b');
  assert.equal(latestFor(data, 'admin'), null);
  assert.equal(latestFor(data, 'investor'), null);
});

test('selection: a partner reads the partner words, else the owner words', () => {
  assert.deepEqual(latestFor(data, 'partner')?.items, ['o41']);
  assert.deepEqual(latestFor(data, 'owner')?.items, ['o41']);
  const withPartner: WnData = { releases: { r43: { date: '2031-03-01', seq: 0, summary: 's', sections: { partners: ['p'], owners: ['o'] } } } };
  assert.deepEqual(latestFor(withPartner, 'partner')?.items, ['p']);
  assert.deepEqual(latestFor(withPartner, 'owner')?.items, ['o']);
});

test('selection: the pop-up shows once per portal; the next release shows again', () => {
  assert.equal(pickPopup(data, 'staff', [])?.release, 'r41b');
  assert.equal(pickPopup(data, 'staff', ['r41b']), null);
  assert.equal(pickPopup(data, 'staff', ['r40'])?.release, 'r41b');
  assert.equal(pickPopup(data, 'renter', ['r41']), null);
  assert.equal(pickPopup(data, 'admin', []), null);
  const next: WnData = { releases: { ...data.releases, r43: { date: '2031-03-01', seq: 0, summary: 's43', sections: { staff: ['c'] } } } };
  assert.equal(pickPopup(next, 'staff', ['r41b'])?.release, 'r43');
});

test('dates read in words', () => {
  assert.equal(prettyDate('2026-11-12'), 'November 12, 2026');
  assert.equal(prettyDate('2026-01-05'), 'January 5, 2026');
  assert.equal(prettyDate('soon'), 'soon');
});
