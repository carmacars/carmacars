// Prints SQL that loads every email template's HTML and text into notification_catalogue.
// The catalogue rows created by migration 0018 hold only the file names (templates/<code>.html);
// the sender renders template_html and template_text, so the file contents must be loaded.
// Usage: node scripts/deploy/email-templates-sql.mjs [offset] [limit] > /tmp/load.sql   (run after `node emails/build.mjs`)
// r26: the database API refuses a request body over its limit, so the deploy loads the templates in parts (offset and
// limit count emails); the last part (offset + limit past the end) ends with the check of what is still a file name.
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const cat = JSON.parse(readFileSync(join(root, 'emails/catalogue.json'), 'utf8'));
const tag = (s) => { let t = 'tpl'; while (s.includes(`$${t}$`)) t += 'x'; return `$${t}$`; };
const lit = (s) => { const t = tag(s); return `${t}${s}${t}`; };
const offset = Number(process.argv[2] ?? 0), limit = Number(process.argv[3] ?? cat.emails.length);
const md5 = (s) => createHash('md5').update(s, 'utf8').digest('hex');
const out = ['begin;'];
let n = 0;
for (const e of cat.emails.slice(offset, offset + limit)) {
  const h = join(root, 'emails', e.template_html), t = join(root, 'emails', e.template_text);
  if (!existsSync(h) || !existsSync(t)) throw new Error(`missing template files for ${e.code}`);
  // 0320: only a template that changed is written (every deploy rewrote every template, a few MB of database log each time)
  // the check compares md5 sums, so each template is sent once (sending it twice made the body too large)
  const hs = readFileSync(h, 'utf8'), ts = readFileSync(t, 'utf8');
  out.push(`update notification_catalogue set template_html = ${lit(hs)}, template_text = ${lit(ts)} where code = '${e.code}' and (md5(coalesce(template_html, '')) <> '${md5(hs)}' or md5(coalesce(template_text, '')) <> '${md5(ts)}' or template_html is null or template_text is null);`);
  n++;
}
const last = offset + limit >= cat.emails.length;
out.push(last ? `select count(*) filter (where template_html like 'templates/%') as still_paths, count(*) as total from notification_catalogue;` : `select ${n} as part;`);
out.push('commit;');
process.stdout.write(out.join('\n') + '\n');
process.stderr.write(`templates: ${n}\n`);
