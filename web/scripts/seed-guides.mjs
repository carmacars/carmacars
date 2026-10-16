// The user guides (migration 0044), seeded from docs/guides/content/<portal>.json (written by docs/guides/src/export.py
// from the guide sources). Run by scripts/seed.mjs with Node's TypeScript support, so the HTML is made by the same
// renderer the Admin's Publish uses (src/features/guides/markdown.ts).
//
// A guide that already has sections is left as it is (an Admin's edits stay); --replace-local rewrites them on the
// local stack only. Each seeded guide is published as version 1.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import postgres from 'postgres';
import { renderGuide } from '../src/features/guides/markdown.ts';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ROOT = path.resolve(WEB, '..');
const DIR = path.join(ROOT, 'docs/guides/content');
const url = process.env.DATABASE_URL || 'postgresql://postgres@127.0.0.1:54322/carmacars';
const replace = process.argv.includes('--replace-local') && /127\.0\.0\.1|localhost/.test(url);
const sql = postgres(url, { onnotice: () => {}, max: 1 });

export async function seedGuides() {
  const out = [];
  if (!fs.existsSync(DIR)) return ['no guide content in this checkout'];
  if (!(await sql`select to_regclass('public.guides') is not null as ok`)[0].ok) return ['the guides tables are not there yet (migration 0044)'];
  for (const portal of ['renter', 'owner', 'admin', 'va', 'field', 'investor']) {
    const f = path.join(DIR, `${portal}.json`);
    if (!fs.existsSync(f)) continue;
    const g = JSON.parse(fs.readFileSync(f, 'utf8'));
    await sql.begin(async (tx) => {
      const [{ n }] = await tx`select count(*)::int as n from guide_sections where portal = ${portal}`;
      if (n > 0 && !replace) { out.push(`${portal}: kept (${n} sections already)`); return; }
      if (n > 0) {
        await tx`delete from guide_section_versions where section_id in (select id from guide_sections where portal = ${portal})`;
        await tx`delete from guide_sections where portal = ${portal}`;
      }
      await tx`update guides set title = ${g.title}, promise = ${g.promise}, signin_url = ${g.signin_url}, lands_on = ${g.lands_on} where portal = ${portal}`;
      const rows = [];
      let order = 0;
      for (const s of g.sections) {
        const [r] = await tx`insert into guide_sections (portal, kind, sort_order, slug, title, blurb, body_md)
                             values (${portal}, ${s.kind}, ${++order}, ${s.slug}, ${s.title}, ${s.blurb}, ${s.body_md}) returning id`;
        await tx`insert into guide_section_versions (section_id, version, title, blurb, body_md, published) values (${r.id}, 1, ${s.title}, ${s.blurb}, ${s.body_md}, false)`;
        rows.push({ ...s, id: r.id });
      }
      const { html, warnings } = renderGuide(rows);
      if (warnings.length) throw new Error(`${portal}: ${warnings.join('; ')}`);
      for (const s of rows) {
        await tx`update guide_sections set published_title = title, published_blurb = blurb, published_md = body_md, published_html = ${html[s.id]},
                   published_hidden = false, published_version = draft_version, published_at = now() where id = ${s.id}`;
        await tx`insert into guide_section_versions (section_id, version, title, blurb, body_md, published) values (${s.id}, 1, ${s.title}, ${s.blurb}, ${s.body_md}, true)`;
      }
      await tx`update guides set version = greatest(version, 0) + 1, published_at = now() where portal = ${portal}`;
      out.push(`${portal}: ${rows.length} sections, published`);
    });
  }
  return out;
}

const report = await seedGuides();
await sql.end();
console.log('   guides: ' + report.join('; '));
