import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { inline, parseImage, render, renderGuide, slugify } from './markdown.ts';

test('nothing the author types becomes raw HTML', () => {
  const r = render('<script>alert(1)</script>\n\n**<img src=x onerror=alert(1)>**\n\n[x](javascript:alert(1))');
  assert.ok(!r.html.includes('<script'));
  assert.ok(!r.html.includes('<img src=x'));
  assert.ok(!r.html.includes('href="javascript'));
  assert.ok(r.html.includes('&lt;script&gt;'));
});

test('inline: button labels, addresses, italic and safe links', () => {
  assert.equal(inline('Press **Save** at `carmacars.ca/owner`'), 'Press <b class="gd-ui">Save</b> at <span class="gd-url">carmacars.ca/owner</span>');
  assert.equal(inline('an *aside* here'), 'an <em>aside</em> here');
  assert.match(inline('[the FAQ](/faq)'), /<a class="gd-a" href="\/faq">the FAQ<\/a>/);
  assert.match(inline('[site](https://carmacars.ca)'), /rel="noopener"/);
  assert.equal(inline('[bad](http://x.test)'), '[bad](http://x.test)');
  assert.equal(inline('`**not bold**`'), '<span class="gd-url">**not bold**</span>');
});

test('images: phone or desktop, size, pins, boxes and the address bar', () => {
  const img = parseImage('![The page](/guides/img/x.jpg "desktop; size: 1440 800; address: carmacars.ca/owner; pins: 1 20.1 74.9, 2 50 50; boxes: 10 20 30 5")');
  assert.deepEqual(img, { src: '/guides/img/x.jpg', alt: 'The page', phone: false, width: 1440, height: 800, address: 'carmacars.ca/owner',
    pins: [{ n: '1', x: 20.1, y: 74.9 }, { n: '2', x: 50, y: 50 }], boxes: [{ x: 10, y: 20, w: 30, h: 5 }] });
  assert.equal(parseImage('![x](/guides/img/p.jpg "phone")')?.phone, true);
  assert.equal(parseImage('![x](javascript:alert(1))'), null);
  assert.equal(parseImage('![x](/a.jpg "pins: 1 140 -5")')?.pins[0]?.x, 100);
});

test('steps: numbers continue from where the list starts, and a screenshot sits beside its steps', () => {
  const r = render('## Pay an invoice\n\n3. Open **Invoices**.\n4. Press **Pay**.\n\n![](/guides/img/p.jpg "phone; size: 390 600; pins: 3 50 50")');
  assert.equal(r.tasks.length, 1);
  assert.equal(r.tasks[0]!.id, 'pay-an-invoice');
  assert.match(r.html, /<ol class="gd-ol" start="3">/);
  assert.match(r.html, /<span class="gd-n" aria-hidden="true">4<\/span>/);
  assert.match(r.html, /gd-stepblock--side/);
  assert.match(r.html, /class="gd-pin" style="left:50%;top:50%"/);
  assert.deepEqual(r.images, ['/guides/img/p.jpg']);
});

test('boxes, tables, flow and phone grids', () => {
  const r = render('> Tip: Use **Save**.\n\n> Watch out: Not twice.\n\n| A | B |\n| --- | --- |\n| 1 | **2** |\n\n:::flow\nNotice | 10 days before\nDebit | the 15th\n:::\n\n:::phones\n1. Tap **Go** ![](/guides/img/a.jpg "phone")\n2. Done ![](/guides/img/b.jpg "phone")\n:::');
  assert.match(r.html, /<aside class="gd-box"><span class="gd-lbl">Tip<\/span>/);
  assert.match(r.html, /gd-box--warn/);
  assert.match(r.html, /<th scope="col">A<\/th>/);
  assert.match(r.html, /<td><b class="gd-ui">2<\/b><\/td>/);
  assert.match(r.html, /<ol class="gd-flow"><li><b>1<\/b><span>Notice<\/span><em>10 days before<\/em><\/li>/);
  assert.equal((r.html.match(/gd-pcell/g) ?? []).length, 2);
  assert.equal(r.warnings.length, 0);
});

test('an unclosed block and a broken image are reported, not hidden', () => {
  const r = render(':::flow\nA | B\n\n![x](not a url)');
  assert.ok(r.warnings.some((w) => w.includes('not closed')));
});

test('anchors are unique within a section and prefixed by the section', () => {
  const r = render('## Same\n\ntext\n\n## Same\n\nmore', { idPrefix: 'money' });
  assert.deepEqual(r.tasks.map((t) => t.id), ['money-same', 'money-same-2']);
  assert.equal(slugify('Fees, payments & payouts'), 'fees-payments-payouts');
});

test('every exported guide renders without a warning, and every image it shows exists', () => {
  const dir = join(import.meta.dirname, '../../../../docs/guides/content');
  const img = new Set(readdirSync(join(import.meta.dirname, '../../../../docs/guides/src/img')));
  for (const f of readdirSync(dir).filter((x) => /^(renter|owner|admin|va|field|investor)\.json$/.test(x))) {
    const g = JSON.parse(readFileSync(join(dir, f), 'utf8')) as { sections: Array<{ slug: string; kind: string; title: string; body_md: string }> };
    const out = renderGuide(g.sections.map((s) => ({ ...s, id: s.slug })));
    assert.deepEqual(out.warnings, [], f);
    for (const s of g.sections) {
      const r = render(s.body_md);
      for (const src of r.images) assert.ok(img.has(src.replace('/guides/img/', '')), `${f}: ${src}`);
    }
    const start = performance.now();
    renderGuide(g.sections.map((s) => ({ ...s, id: s.slug })));
    assert.ok(performance.now() - start < 200, `${f} renders quickly`);
  }
});
