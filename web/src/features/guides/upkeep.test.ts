import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { closestLabels, fakeRewrite, guideLabels, imageLines, missingLabels, normLabel, rewriteProblems, rewritePrompt, sectionAddresses } from './upkeep.ts';
// @ts-expect-error a plain script (web/scripts), no types
import { checkSections, committedSections } from '../../../scripts/guide-labels.mjs';
// @ts-expect-error a plain script (web/scripts), no types
import { labelsOfCode, portalFacts, screenLabels } from '../../../scripts/portal-facts.mjs';

const expect = (got: unknown) => ({
  toEqual: (want: unknown) => assert.deepEqual(got, want),
  toBe: (want: unknown) => assert.equal(got, want),
  toContain: (want: unknown) => assert.ok((got as unknown[] | string).includes(want as never), `expected to contain ${String(want)}`),
  toMatch: (re: RegExp) => assert.match(String(got), re),
  toContainAll: (want: unknown[]) => { for (const w of want) assert.ok((got as unknown[]).includes(w), `expected to contain ${String(w)}`); },
  notToContain: (want: unknown) => assert.ok(!(got as unknown[]).includes(want), `expected not to contain ${String(want)}`)
});

// The guides keep up with the portals (migration 0055): the label check, the facts read from the code, the checks a
// rewrite must pass before it is published.
const IMG = '![](/guides/img/admin-12-owners-desktop-3a54d505.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/owners; pins: 1 41.0 42.9")';

describe('labels', () => {
  it('reads the bold labels of a section, not the first column of a table', () => {
    const md = 'Press **Approve**, then **Send**.\n\n| **Owners** | press **Open** |\n| --- | --- |';
    expect(guideLabels(md).sort()).toEqual(['Approve', 'Open', 'Send']);
  });
  it('compares labels without case, dots or counts', () => {
    expect(normLabel('Pay $...')).toBe('pay $');
    expect(normLabel('Applications (3)')).toBe('applications');
    expect(normLabel('Save the draft.')).toBe('save the draft');
  });
  it('finds a label no screen shows, and accepts labels built from a template', () => {
    const known = ['Approve', '~Invite to the * portal', '~All *', 'Pay $120.00'];
    expect(missingLabels('Press **Approve** or **Approve and set terms**.', known)).toEqual(['Approve and set terms']);
    expect(missingLabels('Press **Invite to the owner portal**, tap **All four**, then **Pay $...**.', known)).toEqual([]);
    expect(missingLabels('Only **once**, and **not** before **$50**.', known)).toEqual([]);
  });
  it('offers the closest labels that exist', () => {
    expect(closestLabels('Approve and set terms', ['Approve', 'Ask for something', 'Set terms (standard grid)', 'Decline'])[0]).toMatch(/Approve|Set terms/);
  });
});

describe('the facts read from the code', () => {
  const facts = portalFacts();
  it('has the seven admin groups and the assistant groups', () => {
    expect(facts.nav.admin.map((g: { group: string }) => g.group)).toEqual(['Today', 'Bookings', 'Cars', 'Owners and partners', 'Money', 'People', 'Settings']);
    expect(facts.nav.admin.find((g: { group: string }) => g.group === 'Owners and partners').links).toContain('Applications');
    expect(facts.nav.va.map((g: { group: string }) => g.group)).toContain('My work');
    expect(facts.nav.owner[0].links).toContain('Documents');
  });
  it('knows the labels of a page from its code', () => {
    const labels = screenLabels(facts, ['/admin/applications/[id]']);
    expect(labels).toContainAll(['Approve', 'Ask for something', 'Decline']);
  });
  it('reads JSX text and strings, not comments', () => {
    const got = labelsOfCode(`// "Old label"\nconst a = 'Send invitation';\n<button>Save the draft</button>\n{pending ? 'Inviting' : \`Invite to the \${role} portal\`}`);
    expect([...got]).toContainAll(['Send invitation', 'Save the draft', 'Inviting', '~Invite to the * portal']);
    expect([...got]).notToContain('Old label');
  });
  it('every button the committed guides name is on a screen of this commit', () => {
    const problems = checkSections(committedSections(), facts);
    expect(problems).toEqual([]);
  });
});

describe('a rewrite', () => {
  const before = `## Owner applications\n\n1. Press **Approve and set terms**.\n\n${IMG}\n`;
  it('passes when it keeps the screenshots and names real buttons', () => {
    expect(rewriteProblems(before, `## Owner applications\n\n1. Press **Approve**.\n\n${IMG}\n`, ['Approve'])).toEqual([]);
  });
  it('is held back when it drops a screenshot, uses an em dash or names a button that does not exist', () => {
    const p = rewriteProblems(before, '## Owner applications\n\n1. Press **Approve now** — done. More words here to keep the length.\n', ['Approve']);
    expect(p.join('; ')).toMatch(/screenshot line/);
    expect(p.join('; ')).toMatch(/em dash/);
    expect(p.join('; ')).toMatch(/Approve now/);
  });
  it('reads the addresses of the screenshots', () => {
    expect(sectionAddresses(`${IMG}\n![](/guides/img/x.jpg "desktop; address: carmacars.ca/admin/owners/628a3315-6335-4e85-a396-f180565d5af5")`)).toEqual(['/admin/owners', '/admin/owners/[id]']);
    expect(imageLines(before)).toEqual([IMG]);
  });
  it('the fake model renames missing buttons to the closest label (local runs and tests)', () => {
    const prompt = rewritePrompt('Owners', before, { portal: 'admin', nav: [], screen_labels: ['Approve'], missing: [{ label: 'Approve and set terms', closest: ['Approve'] }] }, 'It names buttons the portals no longer show');
    const r = fakeRewrite(prompt);
    expect(r.body_md).toContain('Press **Approve**.');
    expect(rewriteProblems(before, r.body_md + '\n', ['Approve'])).toEqual([]);
  });
});
