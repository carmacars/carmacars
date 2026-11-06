// Self-heal that learns (release 28, B6): the I/O of .github/workflows/self-heal.yml. It probes the site and the server
// from outside, reads the ledger (the comments of the one open issue labelled self-heal-ledger) and the fix lines on closed
// self-heal issues, asks web/src/lib/self-heal/decide.ts what to do, does it (vps-ops reboot or apply-retention, re-run a
// failed scheduled workflow, start a backup), opens or closes issues, and appends this run's ledger entries. It never runs
// SQL. Needs GH_TOKEN (issues: write, actions: write) and Node 22.
//   node --experimental-strip-types .github/self-heal/heal.mjs
import { execFileSync } from 'node:child_process';
import { readFileSync, appendFileSync } from 'node:fs';
import { decide } from '../../web/src/lib/self-heal/decide.ts';

const REPO = process.env.GITHUB_REPOSITORY;
const RUN = `${process.env.GITHUB_SERVER_URL}/${REPO}/actions/runs/${process.env.GITHUB_RUN_ID}`;
const VPS = (process.env.LIVE_BACKEND ?? '') === 'vps';
const SITE = 'https://carmacars.ca', API = 'https://api.carmacars.ca';
const runbook = JSON.parse(readFileSync(new URL('./runbook.json', import.meta.url), 'utf8'));
delete runbook._about;
const SCHEDULED = ['backup.yml', 'catalog.yml', 'gsc.yml', 'seo-photos.yml', 'seo-queue.yml', 'usage.yml', 'vps-backup.yml'];
const MARK = '<!-- self-heal-ledger -->';

const gh = (...a) => execFileSync('gh', a, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
const ghj = (...a) => { try { return JSON.parse(gh(...a) || 'null'); } catch { return null; } };
const notice = (m) => console.log(`::notice title=self-heal::${m}`);

async function probe(url, ok, tries = 3) {
  let last = { code: 0, ms: 0, body: '' };
  for (let i = 0; i < tries; i++) {
    const t0 = Date.now();
    try {
      const r = await fetch(url, { signal: AbortSignal.timeout(20_000), headers: { 'user-agent': 'carmacars-self-heal' } });
      last = { code: r.status, ms: Date.now() - t0, body: (await r.text()).slice(0, 2000) };
      if (ok.includes(r.status)) return { ...last, ok: true };
    } catch { last = { code: 0, ms: Date.now() - t0, body: '' }; }
    if (i < tries - 1) await new Promise((r) => setTimeout(r, 20_000));
  }
  return { ...last, ok: false };
}
function certDays(host) {
  try {
    const out = execFileSync('bash', ['-c', `echo | timeout 15 openssl s_client -servername ${host} -connect ${host}:443 2>/dev/null | openssl x509 -noout -enddate`], { encoding: 'utf8' });
    const m = /notAfter=(.*)/.exec(out);
    return m ? (new Date(m[1]).getTime() - Date.now()) / 86_400_000 : null;
  } catch { return null; }
}

// ---------------------------------------------------------------- what is seen
const seen = {};
const site = await probe(`${SITE}/api/health`, [200]);
if (!site.ok) {
  let j = null; try { j = JSON.parse(site.body); } catch { /* not JSON */ }
  if (site.code === 503 && j?.error === 'database') seen.site_db_down = `health 503: the database`;
  else seen.site_down = `health HTTP ${site.code}`;
} else {
  if (site.ms > 8000) seen.site_slow = `health took ${site.ms} ms`;
  try { const j = JSON.parse(site.body); if (j.db_schema && j.schema && j.db_schema > j.schema) seen.schema_behind = `website ${j.schema}, database ${j.db_schema}`; } catch { /* fine */ }
}
const api = await probe(`${API}/auth/v1/settings`, [200, 401, 403]);
if (!api.ok) seen.api_down = `auth settings HTTP ${api.code}`;
const mail = await probe(`${SITE}/api/email-status`, [200], 1);
try { if (mail.ok && JSON.parse(mail.body).capped) seen.email_capped = 'email at its daily limit'; } catch { /* fine */ }
const cs = certDays('carmacars.ca'); if (cs !== null && cs < 14) seen.cert_site = `certificate ends in ${cs.toFixed(1)} days`;
const ca = certDays('api.carmacars.ca'); if (ca !== null && ca < 14) seen.cert_api = `certificate ends in ${ca.toFixed(1)} days`;
// the server's own checks (vps-health): the last two runs failed, with disk, WAL or backup in what it said
if (VPS) {
  const runs = ghj('run', 'list', '-R', REPO, '-w', 'vps-health.yml', '-L', '2', '--json', 'conclusion,databaseId,status') ?? [];
  const done = runs.filter((r) => r.status === 'completed');
  if (done.length === 2 && done.every((r) => r.conclusion === 'failure')) {
    const txt = gh('run', 'view', String(done[0].databaseId), '-R', REPO, '--json', 'jobs', '--jq', '[.jobs[].steps[] | select(.conclusion == "failure") | .name] | join(", ")');
    seen[/disk|wal|backup|space/i.test(txt) ? 'server_disk' : 'server_health'] = `vps-health failing (${txt || 'no step named'})`;
  }
}
const backup = (ghj('run', 'list', '-R', REPO, '-w', 'backup.yml', '-L', '1', '--json', 'conclusion,createdAt,status') ?? [])[0];
if (backup && backup.status === 'completed' && (backup.conclusion === 'failure' || Date.now() - new Date(backup.createdAt).getTime() > 30 * 3_600_000)) seen.backup_failed = `backup ${backup.conclusion} at ${backup.createdAt}`;
const failedRuns = {};
for (const w of SCHEDULED.filter((x) => x !== 'backup.yml')) {
  const r = (ghj('run', 'list', '-R', REPO, '-w', w, '-L', '1', '--json', 'conclusion,databaseId,event,status') ?? [])[0];
  if (r && r.status === 'completed' && r.event === 'schedule' && r.conclusion === 'failure') { seen[`cron_failed:${w.replace(/\.yml$/, '')}`] = `${w} run ${r.databaseId} failed`; failedRuns[w.replace(/\.yml$/, '')] = r.databaseId; }
}
notice(`seen: ${Object.keys(seen).join(', ') || 'nothing'}`);

// ---------------------------------------------------------------- the ledger, the fixes, the last vps-ops run
gh('label', 'create', 'self-heal', '-R', REPO, '--color', 'D93F0B', '--description', 'opened by self-heal', '--force');
gh('label', 'create', 'self-heal-ledger', '-R', REPO, '--color', 'BFD4F2', '--description', 'the self-heal ledger (do not close)', '--force');
let ledgerIssue = ghj('issue', 'list', '-R', REPO, '--label', 'self-heal-ledger', '--state', 'open', '--json', 'number', '--jq', '.[0].number');
if (!ledgerIssue) {
  const url = gh('issue', 'create', '-R', REPO, '--label', 'self-heal-ledger', '--title', 'Self-heal ledger', '--body',
    'Every incident self-heal saw: its signature, the action taken and the outcome, one comment per run that changed something. Self-heal reads it to learn; keep it open. Runbook: .github/self-heal/runbook.json.');
  ledgerIssue = Number(url.split('/').pop());
}
// the last 30 days of the ledger (100 comments at most: one per run that changed something)
const since = new Date(Date.now() - 30 * 86_400_000).toISOString();
const comments = ghj('api', `repos/${REPO}/issues/${ledgerIssue}/comments?per_page=100&since=${since}`, '--jq', '[.[].body]') ?? [];
const ledger = comments.flatMap((b) => { if (!String(b).includes(MARK)) return []; try { return JSON.parse(String(b).split('```json')[1].split('```')[0]); } catch { return []; } });
const fixes = [];
for (const i of ghj('issue', 'list', '-R', REPO, '--label', 'self-heal', '--state', 'closed', '-L', '50', '--json', 'body,comments') ?? []) {
  for (const t of [i.body, ...(i.comments ?? []).map((c) => c.body)]) for (const m of String(t ?? '').matchAll(/self-heal:\s*([a-z_:.-]+)\s*=>\s*([a-z_]+)/gi)) fixes.push({ signature: m[1], action: m[2].toLowerCase() });
}
const lastVps = (ghj('run', 'list', '-R', REPO, '-w', 'vps-ops.yml', '-L', '1', '--json', 'createdAt') ?? [])[0]?.createdAt ?? null;
// how many runs in a row (every 15 minutes) each signature has been seen: from when its open incident started
const openStart = new Map();
for (const e of [...ledger].sort((a, b) => a.at.localeCompare(b.at))) { if (e.event === 'start') openStart.set(e.signature, e.at); else if (e.event === 'end') openStart.delete(e.signature); }
const streak = Object.fromEntries(Object.keys(seen).map((s) => [s, openStart.has(s) ? 1 + Math.floor((Date.now() - new Date(openStart.get(s)).getTime()) / (14 * 60_000)) : 1]));

const plan = decide({ seen, streak, lastVpsOps: lastVps, fixes, vps: VPS }, runbook, ledger);

// ---------------------------------------------------------------- do it
for (const a of plan.actions) {
  try {
    if (a.action === 'reboot') gh('workflow', 'run', 'vps-ops.yml', '-R', REPO, '-f', 'action=reboot', '-f', 'confirm=REBOOT');
    else if (a.action === 'apply_retention') gh('workflow', 'run', 'vps-ops.yml', '-R', REPO, '-f', 'action=apply-retention');
    else if (a.action === 'dispatch_backup') gh('workflow', 'run', 'backup.yml', '-R', REPO, '-f', 'mode=backup');
    else if (a.action === 'rerun_failed') { const id = failedRuns[a.signature.split(':')[1]]; if (id) gh('run', 'rerun', String(id), '-R', REPO, '--failed'); }
    notice(`${a.signature}: ${a.action} (${a.why})`);
  } catch (e) { console.log(`::warning title=self-heal::${a.signature}: ${a.action} could not start: ${String(e.stderr ?? e).slice(0, 200)}`); }
}
const issues = ghj('issue', 'list', '-R', REPO, '--label', 'self-heal', '--state', 'open', '--json', 'number,title') ?? [];
for (const i of plan.issues) {
  const found = issues.find((x) => x.title.includes(`"${i.signature}"`) || x.title.endsWith(`[${i.signature}]`));
  const body = `${i.body}\n\nRun: ${RUN}`;
  const outage = i.signature === 'site_down' || i.signature === 'api_down' || i.signature === 'site_db_down';
  if (found) gh('issue', 'comment', String(found.number), '-R', REPO, '--body', body);
  else gh('issue', 'create', '-R', REPO, '--label', outage ? 'self-heal,outage' : 'self-heal', '--title', `${i.title} [${i.signature}]`, '--body', body);
}
for (const s of plan.ended) {
  for (const x of issues.filter((y) => y.title.includes(`"${s}"`) || y.title.endsWith(`[${s}]`))) {
    gh('issue', 'comment', String(x.number), '-R', REPO, '--body', `Recovered (${new Date().toISOString()}). Run: ${RUN}. If a person fixed it, add a line "self-heal: ${s} => <action>" with the safe action that would have fixed it, and self-heal learns it.`);
    gh('issue', 'close', String(x.number), '-R', REPO, '--reason', 'completed');
  }
}
if (plan.ledger.length) gh('issue', 'comment', String(ledgerIssue), '-R', REPO, '--body', `${MARK}\n\`\`\`json\n${JSON.stringify(plan.ledger)}\n\`\`\`\nRun: ${RUN}`);
if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `site=${seen.site_down || seen.site_db_down ? 'down' : 'ok'}\napi=${seen.api_down ? 'down' : 'ok'}\n`);
notice(`actions: ${plan.actions.map((a) => `${a.signature}=${a.action}`).join(', ') || 'none'}; issues: ${plan.issues.length}; ended: ${plan.ended.join(', ') || 'none'}`);
