import { test } from 'node:test';
import assert from 'node:assert/strict';
import { apiDownloadUrl, apiListUrl, byFileName, FOLDER_MIME, htmlReason, imageKindOf, isJunkName, mergeEntries, parseApiList, parseDriveLink, parseEmbeddedView, parseFolderPage, publicDownloadUrl, sniffBytes, thumbnailUrl, unescapeJsString } from './drive-folder.ts';

// Synthetic pages: made-up ids (example only), shaped as Drive's folder page and embedded view are.
const id = (n: number) => `SyntheticId${String(n).padStart(6, '0')}`;
/** the page escapes quotes, brackets and backslashes as \xNN inside a single-quoted string */
const esc = (v: unknown) => JSON.stringify(v).replace(/[\\"'[\]{}]/g, (c) => `\\x${c.charCodeAt(0).toString(16).padStart(2, '0')}`);
const page = (children: unknown[]) => `<!doctype html><html><head><script nonce="x">window['_DRIVE_ivd'] = '${esc([children, null, 'x'])}';</script></head><body>Example folder</body></html>`;

test('parseDriveLink: folder and file links in the usual shapes', () => {
  assert.deepEqual(parseDriveLink(`https://drive.google.com/drive/folders/${id(1)}?usp=sharing`), { kind: 'folder', id: id(1) });
  assert.deepEqual(parseDriveLink(`drive.google.com/drive/u/0/folders/${id(2)}`), { kind: 'folder', id: id(2) });
  assert.deepEqual(parseDriveLink(`https://drive.google.com/file/d/${id(3)}/view`), { kind: 'file', id: id(3) });
  assert.deepEqual(parseDriveLink(`https://drive.google.com/open?id=${id(4)}`), { kind: 'file', id: id(4) });
  assert.deepEqual(parseDriveLink(`https://drive.google.com/embeddedfolderview?id=${id(5)}`), { kind: 'folder', id: id(5) });
  assert.equal(parseDriveLink('https://example.test/drive/folders/abc'), null);
  assert.equal(parseDriveLink('https://drive.google.com/drive/my-drive'), null);
  assert.equal(parseDriveLink(''), null);
  assert.equal(parseDriveLink('not a link'), null);
});

test('unescapeJsString: \\x, \\u and plain escapes', () => {
  assert.equal(unescapeJsString('\\x5b\\x22a\\x22\\x5d'), '["a"]');
  assert.equal(unescapeJsString('caf\\u00e9 \\/ \\\\ \\\''), "café / \\ '");
});

test('parseFolderPage: folders and files, names with quotes and accents', () => {
  const r = parseFolderPage(page([
    [id(10), [id(1)], 'Mercedes', FOLDER_MIME],
    [id(11), [id(1)], 'IMG_0001.jpg', 'image/jpeg'],
    [id(12), [id(1)], 'Citroën "C4" photo.PNG', 'image/png'],
    [id(13), [id(1)], 'notes.txt', 'text/plain'],
    ['short', [id(1)], 'bad id.jpg', 'image/jpeg'],
    [id(14), [id(1)], 5, 'image/jpeg']
  ]));
  assert.equal(r.found, true);
  assert.deepEqual(r.entries.map((e) => [e.id, e.name, e.folder]), [[id(10), 'Mercedes', true], [id(11), 'IMG_0001.jpg', false], [id(12), 'Citroën "C4" photo.PNG', false], [id(13), 'notes.txt', false]]);
  assert.equal(r.maybeMore, false);
});

test('parseFolderPage: the folder\'s own name from the page title', () => {
  const html = page([[id(10), [id(1)], 'a.jpg', 'image/jpeg']]).replace('<head>', '<head><title>2023 C300 &amp; co - Google Drive</title>');
  assert.equal(parseFolderPage(html).title, '2023 C300 & co');
  assert.equal(parseFolderPage(page([])).title, undefined);
});

test('parseFolderPage: 50 entries means the page may hold only its first page; an empty folder is found; no data is not found', () => {
  const many = Array.from({ length: 50 }, (_, i) => [id(100 + i), [id(1)], `p${i}.jpg`, 'image/jpeg']);
  const r = parseFolderPage(page(many));
  assert.equal(r.entries.length, 50);
  assert.equal(r.maybeMore, true);
  const empty = parseFolderPage(`<script>window['_DRIVE_ivd'] = '${esc([null, null])}';</script>`);
  assert.deepEqual([empty.found, empty.entries.length], [true, 0]);
  assert.equal(parseFolderPage('<html>Sign in</html>').found, false);
  assert.equal(parseFolderPage("<script>window['_DRIVE_ivd'] = 'not json';</script>").found, false);
});

test('parseEmbeddedView: entries with ids, titles and folder links', () => {
  const html = `<html><body><div class="flip-entries">
    <div class="flip-entry" id="entry-${id(20)}" tabindex="0"><a href="https://drive.google.com/drive/folders/${id(20)}" target="_blank"><div class="flip-entry-info"><div class="flip-entry-title">Range Rover &amp; co</div></div></a></div>
    <div class="flip-entry" id="entry-${id(21)}"><a href="https://drive.google.com/file/d/${id(21)}/view?usp=drive_web"><div class="flip-entry-title">front 1.JPG</div></a></div>
    <div class="flip-entry" id="entry-${id(21)}"><a href="https://drive.google.com/file/d/${id(21)}/view"><div class="flip-entry-title">front 1.JPG</div></a></div>
    <div class="flip-entry" id="entry-${id(22)}"><a href="https://drive.google.com/file/d/${id(22)}/view"><div class="flip-entry-title"></div></a></div>
  </div></body></html>`;
  const r = parseEmbeddedView(html);
  assert.deepEqual(r.entries.map((e) => [e.id, e.name, e.folder, e.mime]), [[id(20), 'Range Rover & co', true, FOLDER_MIME], [id(21), 'front 1.JPG', false, 'image/jpeg']]);
  assert.equal(parseEmbeddedView('<html></html>').found, false);
});

test('mergeEntries: by id, the first list wins', () => {
  const a = [{ id: id(1), name: 'a', mime: 'image/jpeg', folder: false }];
  const b = [{ id: id(1), name: 'other', mime: 'image/jpeg', folder: false }, { id: id(2), name: 'b', mime: 'image/png', folder: false }];
  assert.deepEqual(mergeEntries(a, b).map((e) => e.name), ['a', 'b']);
});

test('the API: list address, answer, next page, download address', () => {
  const u = new URL(apiListUrl(id(1), 'KEY-example', 'tok'));
  assert.equal(u.origin + u.pathname, 'https://www.googleapis.com/drive/v3/files');
  assert.equal(u.searchParams.get('q'), `'${id(1)}' in parents and trashed = false`);
  assert.equal(u.searchParams.get('pageToken'), 'tok');
  assert.equal(u.searchParams.get('key'), 'KEY-example');
  const r = parseApiList({ nextPageToken: 'n2', files: [{ id: id(1), name: 'a.jpg', mimeType: 'image/jpeg', size: '1200' }, { id: id(2), name: 'sub', mimeType: FOLDER_MIME }, { id: 'x', name: 'bad' }, { name: 'noid' }] });
  assert.equal(r.next, 'n2');
  assert.deepEqual(r.entries.map((e) => [e.name, e.folder, e.size ?? null]), [['a.jpg', false, 1200], ['sub', true, null]]);
  assert.equal(parseApiList({}).next, null);
  assert.match(apiDownloadUrl(id(1), 'K'), /files\/SyntheticId000001\?alt=media&supportsAllDrives=true&key=K$/);
  assert.equal(publicDownloadUrl(id(1)), `https://drive.usercontent.google.com/download?id=${id(1)}&export=download&confirm=t`);
  assert.equal(thumbnailUrl(id(1), 1024), `https://drive.google.com/thumbnail?id=${id(1)}&sz=w1024`, 'r40: the sorter\'s small copy');
  assert.equal(thumbnailUrl(id(1), 99999), `https://drive.google.com/thumbnail?id=${id(1)}&sz=w2000`);
});

test('imageKindOf: images by mime or extension; junk, videos and documents are not photos', () => {
  assert.equal(imageKindOf({ name: 'a.JPG', mime: 'image/jpeg' }), 'jpeg');
  assert.equal(imageKindOf({ name: 'a.jpeg' }), 'jpeg');
  assert.equal(imageKindOf({ name: 'b.png', mime: 'application/octet-stream' }), 'png');
  assert.equal(imageKindOf({ name: 'c.HEIC', mime: 'image/heic' }), 'heic');
  assert.equal(imageKindOf({ name: 'c.heif' }), 'heic');
  assert.equal(imageKindOf({ name: 'd.webp', mime: 'image/webp' }), 'webp');
  assert.equal(imageKindOf({ name: 'movie.mp4', mime: 'video/mp4' }), null);
  assert.equal(imageKindOf({ name: 'scan.pdf', mime: 'application/pdf' }), null);
  assert.equal(imageKindOf({ name: 'logo.gif', mime: 'image/gif' }), null);
  assert.equal(imageKindOf({ name: '.DS_Store', mime: 'application/octet-stream' }), null);
  assert.equal(imageKindOf({ name: '._IMG_1.jpg', mime: 'image/jpeg' }), null);
  assert.equal(imageKindOf({ name: 'Thumbs.db' }), null);
  for (const n of ['.DS_Store', 'Thumbs.db', 'desktop.ini', '._x', '.hidden', '']) assert.equal(isJunkName(n), true, n);
  assert.equal(isJunkName('front.jpg'), false);
});

test('sniffBytes: the bytes decide, not the name', () => {
  assert.equal(sniffBytes(new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0])), 'jpeg');
  assert.equal(sniffBytes(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a])), 'png');
  assert.equal(sniffBytes(new TextEncoder().encode('RIFF\0\0\0\0WEBPVP8 ')), 'webp');
  assert.equal(sniffBytes(new Uint8Array([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63, 0, 0])), 'heic');
  assert.equal(sniffBytes(new TextEncoder().encode('<!DOCTYPE html><html><title>Google Drive - Virus scan warning</title>')), 'html');
  assert.equal(sniffBytes(new TextEncoder().encode('%PDF-1.7')), 'other');
  assert.match(htmlReason(new TextEncoder().encode('<html>Sorry, you can\'t view or download this file at this time. Too many users have viewed or downloaded this file recently (download quota)')), /too many downloads/);
  assert.match(htmlReason(new TextEncoder().encode('<html><a href="https://accounts.google.com/ServiceLogin">Sign in</a></html>')), /not shared/);
});

test('byFileName: numbers in order', () => {
  assert.deepEqual([{ name: 'IMG_10.jpg' }, { name: 'IMG_2.jpg' }, { name: 'img_1.jpg' }].sort(byFileName).map((x) => x.name), ['img_1.jpg', 'IMG_2.jpg', 'IMG_10.jpg']);
});
