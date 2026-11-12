// Worker runtime smoke (ci.yml, the e2e job "desktop-1440 4/4"; r38): the OpenNext Worker build, run in workerd by
// `wrangler dev` in local mode, answers a few pages without crashing. `next start` (scripts/serve.mjs), which the
// end-to-end tests use, never runs the Worker, so a Worker-only crash passed every test: on Nov 11 a Next.js bump made
// every rendered request throw "Unexpected loadManifest(/.next/server/preview-props.json)" (Error 1101 in production).
//
//   node scripts/worker-smoke.mjs            after `npm run cf:build`, with .env.local (the local stack) in place
//
// No secrets and no Cloudflare account: the config is wrangler.jsonc without what only exists remotely (the Workers AI
// binding, the custom domains), and the runtime values are .env.local's (the local database; fakes for every provider),
// put in .dev.vars, which override wrangler.jsonc's production vars. Fails on a 5xx, an "Error 1101" or "Worker threw"
// page, or an uncaught exception in wrangler's log.
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = Number(process.env.SMOKE_PORT || 8787);
const BASE = `http://127.0.0.1:${PORT}`;
const CONFIG = path.join(WEB, '.wrangler-smoke.jsonc');
const LOG = process.env.SMOKE_LOG || '/tmp/worker-smoke.log';

// wrangler.jsonc without its comments (strings kept as they are: a URL's "//" is not a comment)
function stripJsonc(text) {
  let out = '', i = 0, inStr = false;
  while (i < text.length) {
    const c = text[i], n = text[i + 1];
    if (inStr) { out += c; if (c === '\\') { out += n ?? ''; i += 2; continue; } if (c === '"') inStr = false; i++; continue; }
    if (c === '"') { inStr = true; out += c; i++; continue; }
    if (c === '/' && n === '/') { while (i < text.length && text[i] !== '\n') i++; continue; }
    if (c === '/' && n === '*') { i = text.indexOf('*/', i + 2); i = i < 0 ? text.length : i + 2; continue; }
    out += c; i++;
  }
  return out.replace(/,(\s*[}\]])/g, '$1');
}

const cfg = JSON.parse(stripJsonc(fs.readFileSync(path.join(WEB, 'wrangler.jsonc'), 'utf8')));
delete cfg.ai;          // remote only: wrangler dev would need a Cloudflare token (LLM_PROVIDER is fake here)
delete cfg.routes;      // the custom domains
cfg.workers_dev = true;
delete cfg.$schema;
fs.writeFileSync(CONFIG, JSON.stringify(cfg, null, 2));

const devVars = path.join(WEB, '.dev.vars');
const hadDevVars = fs.existsSync(devVars);
if (!hadDevVars) {
  const env = fs.readFileSync(path.join(WEB, fs.existsSync(path.join(WEB, '.env.local')) ? '.env.local' : '.env.example'), 'utf8');
  // KEY=value lines only, without the inline comments of .env.example
  const lines = env.split('\n').map((l) => l.replace(/\s+#.*$/, '').trim()).filter((l) => /^[A-Z0-9_]+=/.test(l));
  fs.writeFileSync(devVars, lines.join('\n') + `\nNEXT_PUBLIC_APP_URL=${BASE}\n`);
}

const log = fs.openSync(LOG, 'w');
const dev = spawn(path.join(WEB, 'node_modules/.bin/wrangler'), ['dev', '-c', CONFIG, '--port', String(PORT), '--ip', '127.0.0.1', '--local', '--show-interactive-dev-session=false'],
  { cwd: WEB, stdio: ['ignore', log, log], env: { ...process.env, CLOUDFLARE_API_TOKEN: '', WRANGLER_SEND_METRICS: 'false', CI: 'true' }, detached: true });
const stop = () => { try { process.kill(-dev.pid, 'SIGTERM'); } catch { /* gone */ } };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const problems = [];
try {
  let up = false;
  for (let i = 0; i < 90 && !up; i++) {
    try { await fetch(`${BASE}/robots.txt`, { signal: AbortSignal.timeout(5_000) }); up = true; } catch { await sleep(1_000); }
  }
  if (!up) throw new Error('wrangler dev did not answer within 90 s');
  // one dynamic route: a car page from the local seed when there is one, else a car code that does not exist (a 404)
  const paths = ['/api/health', '/', '/sign-in', '/cars', '/cars/no-such-car-smoke'];
  for (const p of paths) {
    let status = 0, body = '';
    for (let attempt = 1; attempt <= 2; attempt++) {   // the first render of a route compiles in workerd: one retry on a timeout
      try {
        const res = await fetch(BASE + p, { redirect: 'manual', signal: AbortSignal.timeout(60_000) });
        status = res.status; body = await res.text(); break;
      } catch (e) { status = 0; body = String(e); }
    }
    const crash = /Error 1101|Worker threw exception|loadManifest|Unexpected loadManifest/i.test(body);
    console.log(`${p} ${status}${crash ? ' (crash page)' : ''}`);
    if (status === 0 || status >= 500 || crash) problems.push(`${p}: ${status || body.slice(0, 200)}${crash ? ' (Worker crash)' : ''}`);
  }
} catch (e) {
  problems.push(String(e instanceof Error ? e.message : e));
} finally {
  stop();
  await sleep(1_000);
  fs.rmSync(CONFIG, { force: true });
  if (!hadDevVars) fs.rmSync(devVars, { force: true });
}
const text = fs.readFileSync(LOG, 'utf8');
const uncaught = text.split('\n').filter((l) => /Uncaught|loadManifest|Error 1101|Worker threw/i.test(l));
if (uncaught.length) problems.push(...uncaught.slice(0, 10).map((l) => `wrangler: ${l.trim().slice(0, 300)}`));
if (problems.length) {
  console.log(text.split('\n').slice(-60).join('\n'));
  console.log(`::error title=Worker smoke::${problems.join('; ').replace(/\n/g, ' ')}`);
  process.exit(1);
}
console.log(`::notice title=Worker smoke::the Worker build answered ${BASE} in workerd (health, home, sign-in, cars, a car page) without a crash`);
