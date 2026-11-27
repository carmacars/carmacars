// Checks docs/owner/requirements.md (the owner's standing requirements).
//   node scripts/check-requirements.mjs            check (exit 1 on failure)
//   node scripts/check-requirements.mjs --export   also rewrite docs/owner/requirements.json
// Fails if the file is missing, an item lacks its ID, Status, Done when, or a done item lacks
// Proof or Test, or a Test path does not exist, or the JSON export is out of date.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const mdPath = path.join(root, 'docs/owner/requirements.md')
const jsonPath = path.join(root, 'docs/owner/requirements.json')
const STATUS = ['done', 'in progress', 'not started']
const fail = (m) => { console.error('REQUIREMENTS CHECK FAILED: ' + m); process.exit(1) }

if (!fs.existsSync(mdPath)) fail('docs/owner/requirements.md is missing')
const lines = fs.readFileSync(mdPath, 'utf8').split('\n')
const items = []
let area = ''
let cur = null
for (const ln of lines) {
  const a = ln.match(/^## (.*)/)
  if (a) { area = a[1]; cur = null; continue }
  const h = ln.match(/^### (.*)/)
  if (h) {
    const m = h[1].match(/^(REQ-\d{3,}) (.+)/)
    cur = { id: m ? m[1] : '', title: m ? m[2] : h[1], area, fields: {}, heading: h[1] }
    items.push(cur)
    continue
  }
  const f = ln.match(/^- (Status|Asked|Owner|Rule|Done when|Proof|Test): (.*)/)
  if (f && cur) cur.fields[f[1]] = f[2].trim()
}
if (items.length === 0) fail('no items found')
const seen = new Set()
let gaps = 0
for (const it of items) {
  const where = it.heading
  if (!it.id) fail(`item without a REQ-### id: ${where}`)
  if (seen.has(it.id)) fail(`duplicate id ${it.id}`)
  seen.add(it.id)
  const f = it.fields
  if (!STATUS.includes(f['Status'])) fail(`${it.id} Status must be one of ${STATUS.join(', ')}`)
  if (!f['Done when']) fail(`${it.id} has no "Done when" line`)
  if (!f['Asked']) fail(`${it.id} has no "Asked" date`)
  if (f['Status'] === 'done') {
    if (!f['Proof'] || /^none/i.test(f['Proof'])) fail(`${it.id} is done but has no Proof`)
    if (!f['Test']) fail(`${it.id} is done but has no Test line (use "GAP" to record a missing test)`)
    if (/^GAP/i.test(f['Test'])) gaps++
    else for (const p of f['Test'].split(';').map((s) => s.trim())) {
      if (/^(supabase|web|scripts)\//.test(p) && !fs.existsSync(path.join(root, p))) fail(`${it.id} Test path not found: ${p}`)
    }
  }
}
const out = items.map((it) => ({
  id: it.id, title: it.title, area: it.area, status: it.fields['Status'], asked: it.fields['Asked'],
  owner_quote: it.fields['Owner'] ?? null, rule: it.fields['Rule'] ?? null,
  done_when: it.fields['Done when'], proof: it.fields['Proof'] ?? null, test: it.fields['Test'] ?? null,
}))
const json = JSON.stringify(out, null, 2) + '\n'
if (process.argv.includes('--export')) fs.writeFileSync(jsonPath, json)
else if (!fs.existsSync(jsonPath) || fs.readFileSync(jsonPath, 'utf8') !== json) fail('docs/owner/requirements.json is out of date: run node scripts/check-requirements.mjs --export')
const c = (s) => out.filter((x) => x.status === s).length
console.log(`requirements: ${out.length} total, ${c('done')} done, ${c('in progress')} in progress, ${c('not started')} not started, ${gaps} done without a test`)
