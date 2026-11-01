// Prints SQL that loads every email template's HTML and text into notification_catalogue.
// The catalogue rows created by migration 0018 hold only the file names (templates/<code>.html);
// the sender renders template_html and template_text, so the file contents must be loaded.
// Usage: node scripts/deploy/email-templates-sql.mjs > /tmp/load.sql   (run after `node emails/build.mjs`)
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const cat = JSON.parse(readFileSync(join(root, 'emails/catalogue.json'), 'utf8'));
const tag = (s) => { let t = 'tpl'; while (s.includes(`$${t}$`)) t += 'x'; return `$${t}$`; };
const lit = (s) => { const t = tag(s); return `${t}${s}${t}`; };
const out = ['begin;'];
let n = 0;
for (const e of cat.emails) {
  const h = join(root, 'emails', e.template_html), t = join(root, 'emails', e.template_text);
  if (!existsSync(h) || !existsSync(t)) throw new Error(`missing template files for ${e.code}`);
  // 0320: only a template that changed is written (every deploy rewrote every template, a few MB of database log each time)
  const html = lit(readFileSync(h, 'utf8')), text = lit(readFileSync(t, 'utf8'));
  out.push(`update notification_catalogue set template_html = ${html}, template_text = ${text} where code = '${e.code}' and (template_html is distinct from ${html} or template_text is distinct from ${text});`);
  n++;
}
out.push(`select count(*) filter (where template_html like 'templates/%') as still_paths, count(*) as total from notification_catalogue;`);
out.push('commit;');
process.stdout.write(out.join('\n') + '\n');
process.stderr.write(`templates: ${n}\n`);
