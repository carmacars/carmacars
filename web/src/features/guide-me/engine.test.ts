// Guide me (r51, 3950): the step engine and the step files. npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pageFirst, back, canNext, currentStep, evaluate, flowsFor, next, place, progress, routeMatches, selectorOf, skip, startFor, startRun, stepsFor, sync, type Cond, type Flow, type Probe } from './engine.ts';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..', '..', '..');
const FLOWS: Flow[] = readdirSync(join(HERE, 'flows')).filter((f) => f.endsWith('.json')).map((f) => JSON.parse(readFileSync(join(HERE, 'flows', f), 'utf8')) as Flow);

/** A page as a table: the elements there, their values, attributes and what was checked or clicked. */
function page(o: { path?: string; search?: string; els?: string[]; values?: Record<string, string>; attrs?: Record<string, Record<string, string>>; checked?: string[]; clicked?: string[] } = {}): Probe {
  return { path: o.path ?? '/admin/offers/new', search: o.search ?? '', exists: (t) => (o.els ?? []).includes(t) || t in (o.attrs ?? {}), value: (t) => o.values?.[t] ?? null,
    checked: (t) => (o.checked ?? []).includes(t), attr: (t, n) => o.attrs?.[t]?.[n] ?? null, clicked: (t) => (o.clicked ?? []).includes(t) };
}
const flow: Flow = { id: 't', title: 'T', summary: 's', who: ['admin', 'cs'], start: '{base}/x', steps: [
  { id: 'go', text: 'Open it', done: { exists: 'form' }, skipIfDone: true },
  { id: 'name', target: 'name', text: 'Type the name', done: { filled: 'name' } },
  { id: 'read', target: 'info', text: 'Read this' },
  { id: 'opt', target: 'opt', text: 'Only some pages', page: 'form', when: { exists: 'opt' }, done: { checked: 'opt' } },
  { id: 'staff', text: 'Staff only', only: ['va'], done: { exists: 'never' } },
  { id: 'send', target: 'send', text: 'Send', done: { exists: 'sent' } }] };

test('routes: {base}, one segment, the rest, and the query', () => {
  assert.equal(routeMatches('{base}/offers/new', '/staff/offers/new', '', '/staff'), true);
  assert.equal(routeMatches('{base}/offers/new', '/admin/offers/new', '', '/staff'), false, 'the run keeps its base');
  assert.equal(routeMatches('{base}/offers/new', '/admin/offers/new', '', null), true);
  assert.equal(routeMatches('{base}/bookings/*', '/admin/bookings/CC-1001', '', '/admin'), true);
  assert.equal(routeMatches('{base}/bookings/*', '/admin/bookings', '', '/admin'), false);
  assert.equal(routeMatches('{base}/bookings/*/deposit-review', '/staff/bookings/CC-1/deposit-review', '', '/staff'), true);
  assert.equal(routeMatches('/staff/**', '/staff/field/jobs/1', '', null), true);
  assert.equal(routeMatches('{base}/bookings/*?tab=money', '/admin/bookings/CC-1', '?tab=money&x=1', '/admin'), true);
  assert.equal(routeMatches('{base}/bookings/*?tab=money', '/admin/bookings/CC-1', '?tab=review', '/admin'), false);
  assert.equal(routeMatches('/staff/field', '/staff/field/', '', null), true);
});

test('conditions read the real state of the page', () => {
  const pr = page({ els: ['a'], values: { f: ' x ', e: '  ' }, attrs: { r: { 'data-missing': 'renter dates', 'data-ok': 'yes' } }, checked: ['c'], clicked: ['k'] });
  const t = (c: Cond) => evaluate(c, pr, '/admin');
  assert.equal(t({ exists: 'a' }), true); assert.equal(t({ gone: 'a' }), false);
  assert.equal(t({ filled: 'f' }), true); assert.equal(t({ filled: 'e' }), false, 'spaces are not filled'); assert.equal(t({ filled: 'none' }), false);
  assert.equal(t({ checked: 'c' }), true); assert.equal(t({ clicked: 'k' }), true); assert.equal(t({ clicked: 'a' }), false);
  assert.equal(t({ attr: 'r', name: 'data-ok', equals: 'yes' }), true);
  assert.equal(t({ attr: 'r', name: 'data-missing', excludes: ['car'] }), true);
  assert.equal(t({ attr: 'r', name: 'data-missing', excludes: ['renter'] }), false);
  assert.equal(t({ attr: 'r', name: 'data-missing', includes: 'dates' }), true);
  assert.equal(t({ attr: 'nothing', name: 'x', excludes: [] }), false, 'no element: not done');
  assert.equal(t({ all: [{ exists: 'a' }, { checked: 'c' }] }), true); assert.equal(t({ any: [{ exists: 'zz' }, { gone: 'zz' }] }), true); assert.equal(t({ not: { exists: 'a' } }), false);
  assert.equal(t({ route: '{base}/offers/new' }), true);
  assert.equal(selectorOf('offer-send'), '[data-guide="offer-send"]');
  assert.equal(selectorOf('[data-guide="x"] input'), '[data-guide="x"] input');
});

test('a step to do advances only when it is really done; Next stays off until then', () => {
  let r = startRun(flow, 'admin', '/admin', 1);
  assert.deepEqual(r.steps, ['go', 'name', 'read', 'opt', 'send'], 'the staff-only step is not in an Admin run');
  // the page is there already: "open it" passes by itself
  let o = sync(flow, r, page({ els: ['form', 'name'] }));
  assert.equal(currentStep(flow, o.run)?.id, 'name');
  r = o.run;
  assert.equal(canNext(currentStep(flow, r)!, page({ els: ['form'] }), '/admin'), false, 'Next is off while the name is empty');
  assert.equal(next(flow, r, page({ els: ['form'] })).run.index, r.index, 'Next does not pass a step to do');
  o = sync(flow, r, page({ els: ['form'], values: { name: 'Ada' } }));
  assert.equal(currentStep(flow, o.run)?.id, 'read', 'typed: it moved on by itself');
  // a step to read waits for Next
  o = sync(flow, o.run, page({ els: ['form'], values: { name: 'Ada' } }));
  assert.equal(currentStep(flow, o.run)?.id, 'read');
  o = next(flow, o.run, page({ els: ['form', 'opt'], values: { name: 'Ada' } }));
  assert.equal(currentStep(flow, o.run)?.id, 'opt');
  assert.deepEqual(progress(o.run), { at: 4, of: 5 });
});

test('a step already done when it opens shows Done and waits for Next (nothing passed unseen)', () => {
  const r0 = { ...startRun(flow, 'admin', '/admin', 1), index: 1 };
  const pr = page({ els: ['form'], values: { name: 'Ada' } });
  const r = back(flow, { ...r0, index: 2 }, pr);
  assert.equal(r.index, 1); assert.equal(r.held, true);
  assert.equal(sync(flow, r, pr).run.index, 1, 'Back holds: no jump forward again');
  assert.equal(canNext(currentStep(flow, r)!, pr, '/admin'), true, 'done: Next is on');
  assert.equal(next(flow, r, pr).run.index, 2);
  // opened while already done (not by Back): it waits too
  const opened = { ...r0, openedDone: true };
  assert.equal(sync(flow, opened, pr).run.index, 1);
  // undone and done again: then it moves on by itself
  const undone = sync(flow, opened, page({ els: ['form'] })).run;
  assert.equal(undone.openedDone, false);
  assert.equal(sync(flow, undone, pr).run.index, 2);
});

test('a part this page does not have is left out once the page has loaded; Skip records the step; the last step completes', () => {
  const r = { ...startRun(flow, 'admin', '/admin', 1), index: 3 };
  assert.equal(sync(flow, r, page({ els: [] })).run.index, 3, 'the page not loaded yet: wait');
  assert.equal(currentStep(flow, sync(flow, r, page({ els: ['form'] })).run)?.id, 'send', 'loaded, no such part: left out');
  const s = skip(flow, r, page({ els: ['form', 'opt'] }));
  assert.deepEqual(s.run.skipped, ['opt']);
  assert.equal(currentStep(flow, s.run)?.id, 'send');
  const done = sync(flow, s.run, page({ els: ['form', 'sent'] }));
  assert.equal(done.kind, 'completed');
  assert.equal(skip(flow, { ...s.run }, page({ els: ['form'] })).kind, 'completed', 'skipping the last step ends the run');
});

test('who sees which workflow, the steps of a portal, and where each starts', () => {
  assert.deepEqual(flowsFor([flow], { admin: true, functions: [] }).map((f) => f.id), ['t']);
  assert.deepEqual(flowsFor([flow], { admin: false, functions: ['cs'] }).map((f) => f.id), ['t']);
  assert.deepEqual(flowsFor([flow], { admin: false, functions: ['fleet'] }).map((f) => f.id), []);
  assert.deepEqual(stepsFor(flow, 'va').map((s) => s.id), ['go', 'name', 'read', 'opt', 'staff', 'send']);
  assert.equal(startFor(flow, 'va', '/staff'), '/staff/x');
  assert.equal(startFor({ ...flow, start: { field: '/staff/field', admin: '{base}/bookings' } }, 'admin', '/admin'), '/admin/bookings');
});

test('the card stays on screen at 320 and 375 px and never covers Report a bug', () => {
  for (const w of [320, 375, 1440]) {
    const view = { w, h: 700 };
    const g = w < 360 ? 8 : 16;
    const p = place({ x: w - 60, y: 100, w: 50, h: 30 }, { w: 352, h: 150 }, view);
    assert.ok(p.x >= g - 0.01 && p.x + Math.min(352, w - 2 * g) <= w - g + 0.01, `inside the screen at ${w}`);
    assert.equal(p.side, 'below');
  }
  const bug = { x: 300, y: 130, w: 60, h: 40 };
  const p = place({ x: 280, y: 90, w: 80, h: 30 }, { w: 300, h: 150 }, { w: 375, h: 700 }, [bug]);
  const overlap = p.x < bug.x + bug.w && bug.x < p.x + 300 && p.y < bug.y + bug.h && bug.y < p.y + 150;
  assert.equal(overlap, false, 'moved off Report a bug');
  const low = place({ x: 10, y: 640, w: 100, h: 40 }, { w: 300, h: 150 }, { w: 375, h: 700 });
  assert.equal(low.side, 'above', 'no room below: above');
  const none = place(null, { w: 300, h: 150 }, { w: 375, h: 700 }, [{ x: 0, y: 520, w: 375, h: 180 }]);
  assert.equal(none.side, 'float'); assert.ok(none.y + 150 <= 520 || none.y >= 700, 'the corner card is clear of what it must leave free');
});

// ---------------------------------------------------------------- the step files
function sources(dir: string): string[] {
  const out: string[] = [];
  for (const f of readdirSync(dir)) {
    const p = join(dir, f);
    if (statSync(p).isDirectory()) out.push(...sources(p)); else if (/\.tsx?$/.test(f) && !f.endsWith('.test.ts')) out.push(readFileSync(p, 'utf8'));
  }
  return out;
}
const code = sources(join(ROOT, 'web', 'src')).join('\n');
const literal = new Set([...code.matchAll(/data-guide=(?:"([a-z0-9-]+)"|\{'([a-z0-9-]+)'\}|\{[^}]*?'([a-z0-9-]+)'\s*:)/g)].map((m) => m[1] ?? m[2] ?? m[3]!));
for (const m of code.matchAll(/data-guide=\{([^}]*)\}/g)) for (const q of m[1]!.matchAll(/'([a-z0-9-]+)'/g)) literal.add(q[1]!);
// the admin kit's Card and the offer's steps take the name as guide
for (const m of code.matchAll(/<Card [^>]*?\bguide="([a-z0-9-]+)"/g)) literal.add(m[1]!);
for (const m of code.matchAll(/\bguide: '([a-z0-9-]+)'/g)) literal.add(m[1]!);
const prefixes = [...code.matchAll(/data-guide=\{`([a-z0-9-]*)\$\{/g)].map((m) => m[1]!).filter(Boolean);
// a template from a known id: Checklist parts (ho-<part>), the field job cards, the Whose money? fieldset and the channel radios
const known = (t: string) => literal.has(t) || prefixes.some((p) => t.startsWith(p)) || ['money-whose', 'money-receipt', 'bm-rhow-record'].includes(t);
const targetsOf = (c: Cond | undefined): string[] => !c ? [] : 'all' in c ? c.all.flatMap(targetsOf) : 'any' in c ? c.any.flatMap(targetsOf) : 'not' in c ? targetsOf(c.not) : 'route' in c ? [] : [Object.values(c)[0] as string];

test('every step file is whole: unique ids, an instruction, known portals and functions', () => {
  assert.ok(FLOWS.length >= 40, 'every portal has its workflows');
  assert.equal(new Set(FLOWS.map((f) => f.id)).size, FLOWS.length);
  for (const f of FLOWS) {
    assert.match(f.id, /^[a-z0-9-]{2,60}$/);
    assert.ok(f.title && f.summary && f.steps.length >= 2 && f.steps.length <= 60, f.id);
    assert.ok(f.who.every((w) => ['admin', 'cs', 'sales', 'fleet', 'finance', 'field', 'owner', 'renter', 'investor', 'visitor'].includes(w)), f.id);
    assert.equal(new Set(f.steps.map((s) => s.id)).size, f.steps.length, `${f.id}: step ids`);
    for (const s of f.steps) {
      assert.match(s.id, /^[a-z0-9-]{1,60}$/);
      assert.ok(s.text.length >= 8 && s.text.length <= 220, `${f.id}/${s.id}: one short instruction`);
      assert.ok(!s.only || s.only.every((p) => ['admin', 'va', 'field', 'owner', 'renter', 'investor', 'public'].includes(p)), `${f.id}/${s.id}: only`);
    }
    for (const p of ['admin', 'va', 'field', 'owner', 'renter', 'investor', 'public'] as const) {
      if (!stepsFor(f, p).length) continue;
      assert.ok(startFor(f, p, p === 'admin' ? '/admin' : '/staff').startsWith('/'), `${f.id}: starts somewhere for ${p}`);
    }
  }
});

test('every element a step names carries its data-guide in the code (no CSS classes)', () => {
  for (const f of FLOWS) for (const s of f.steps) {
    for (const t of [s.target, s.page, ...targetsOf(s.done), ...targetsOf(s.when)].filter(Boolean) as string[]) {
      assert.match(t, /^[a-z0-9-]+$/, `${f.id}/${s.id}: ${t} is a data-guide name`);
      assert.ok(known(t), `${f.id}/${s.id}: no element has data-guide="${t}"`);
    }
  }
});

test('every workflow follows a published guide chapter (the wording is not duplicated)', () => {
  for (const f of FLOWS) {
    assert.ok(f.guide, `${f.id}: names its guide chapter`);
    const g = JSON.parse(readFileSync(join(ROOT, 'docs', 'guides', 'content', `${f.guide!.portal}.json`), 'utf8')) as { sections: Array<{ slug: string }> };
    assert.ok(g.sections.some((s) => s.slug === f.guide!.slug), `${f.id}: ${f.guide!.portal}/${f.guide!.slug} exists`);
  }
});

test('owners, renters, investors and visitors see their own workflows; the help menu lists this page first', () => {
  const ids = (o: Parameters<typeof flowsFor>[1]) => flowsFor(FLOWS, o).map((f) => f.id);
  const renter = ids({ admin: false, functions: [], portal: 'renter' });
  assert.ok(renter.includes('renter-sign-pay') && renter.includes('renter-signup') && !renter.includes('create-offer') && !renter.includes('owner-money'));
  const owner = ids({ admin: false, functions: [], portal: 'owner' });
  assert.ok(owner.includes('owner-money') && !owner.includes('renter-rewards') && !owner.includes('renter-signup'));
  const pub = ids({ admin: false, functions: [], portal: 'public' });
  assert.ok(pub.includes('renter-signup') && pub.includes('renter-book') && pub.includes('owner-apply') && !pub.includes('renter-rewards'));
  assert.ok(ids({ admin: false, functions: [], portal: 'investor' }).every((f) => f.startsWith('investor-')));
  assert.equal(flowsFor(FLOWS, { admin: false, functions: ['finance'], portal: 'va' }).some((f) => !f.who.includes('finance')), false, 'staff do not see the renter or owner walkthroughs');
  // every staff function and every portal has workflows
  for (const fn of ['cs', 'sales', 'fleet', 'finance', 'field']) assert.ok(ids({ admin: false, functions: [fn], portal: fn === 'field' ? 'field' : 'va' }).length >= 4, fn);
  const g = pageFirst(flowsFor(FLOWS, { admin: false, functions: [], portal: 'owner' }), 'owner', '/owner/money', '');
  assert.ok(g.here.some((f) => f.id === 'owner-money'), 'the page\'s own workflow first');
  assert.ok(!g.rest.some((f) => f.id === 'owner-money'));
  assert.equal(g.here.length + g.rest.length, flowsFor(FLOWS, { admin: false, functions: [], portal: 'owner' }).length);
});

test('every step file is a workflow people can start (flows.ts lists each one)', async () => {
  const src = readFileSync(join(HERE, 'flows.ts'), 'utf8');
  const imported = [...src.matchAll(/^import (\w+) from '\.\/flows\/([a-z0-9-]+)\.json';$/gm)];
  const list = /export const FLOWS: Flow\[\] = \[([^\]]*)\]/.exec(src)?.[1]?.split(',').map((s) => s.trim()) ?? [];
  assert.deepEqual(imported.map((m) => m[2]).sort(), readdirSync(join(HERE, 'flows')).filter((f) => f.endsWith('.json')).map((f) => f.slice(0, -5)).sort(), 'every file is imported');
  assert.deepEqual([...list].sort(), imported.map((m) => m[1]).sort(), 'every import is in FLOWS');
});
