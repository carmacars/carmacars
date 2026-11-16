// r48 (3070): scripts/deploy/cf-site.sh against a small stand-in of Cloudflare's API (no network, no token): the cutover's
// steps A and B, their rollback, idempotency, the Origin CA certificate, and a token without some permissions.
//   node --test scripts/deploy/cf-site.test.mjs        (needs bash, curl, jq, openssl; run by deploy-vps node-smoke)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(HERE, 'cf-site.sh');
const IP = '54.39.111.152';
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'cf-site-'));

// a stand-in for Cloudflare's Origin CA: signs the CSR for the hostnames asked, issuer "CloudFlare Origin SSL ECC ..."
execFileSync('openssl', ['ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', `${tmp}/ca.key`]);
execFileSync('openssl', ['req', '-x509', '-new', '-key', `${tmp}/ca.key`, '-days', '30', '-subj', '/O=CloudFlare, Inc./OU=CloudFlare Origin SSL ECC Certificate Authority/CN=test', '-out', `${tmp}/ca.pem`]);
function sign(csr, hostnames, days) {
  fs.writeFileSync(`${tmp}/req.csr`, csr);
  fs.writeFileSync(`${tmp}/ext.cnf`, `subjectAltName=${hostnames.map((h) => `DNS:${h}`).join(',')}\n`);
  execFileSync('openssl', ['x509', '-req', '-in', `${tmp}/req.csr`, '-CA', `${tmp}/ca.pem`, '-CAkey', `${tmp}/ca.key`, '-CAcreateserial', '-days', String(days), '-extfile', `${tmp}/ext.cnf`, '-out', `${tmp}/leaf.pem`], { stdio: 'ignore' });
  return fs.readFileSync(`${tmp}/leaf.pem`, 'utf8');
}

function world() {
  return {
    deny: new Set(), // "METHOD /path-prefix" refused with 9109
    records: [
      { id: 'r1', type: 'MX', name: 'carmacars.ca', content: 'mx.example', proxied: false },
      { id: 'r2', type: 'A', name: 'new.carmacars.ca', content: '192.0.2.9', proxied: false }
    ],
    settings: { ssl: 'full', always_use_https: 'on', ssl_automatic_mode: 'auto' },
    location: false,
    domains: [
      { id: 'd1', hostname: 'carmacars.ca', service: 'carmacars-prod' },
      { id: 'd2', hostname: 'www.carmacars.ca', service: 'carmacars-prod' },
      { id: 'd3', hostname: 'shop.carmacars.ca', service: 'other-worker' }
    ],
    routes: [{ id: 'w1', pattern: 'www.carmacars.ca/*', script: 'carmacars-prod' }, { id: 'w2', pattern: 'blog.carmacars.ca/*', script: 'carmacars-prod' }],
    crons: [{ cron: '* * * * *' }],
    certs: 0,
    certDays: 5475,
    n: 10
  };
}
let W = world();

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    const u = new URL(req.url, 'http://x');
    const p = u.pathname.replace(/^\/client\/v4/, '');
    const ok = (result) => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ success: true, errors: [], result })); };
    const no = (code, msg, status = 400) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify({ success: false, errors: [{ code, message: msg }] })); };
    for (const d of W.deny) { const [m, pre] = d.split(' '); if (req.method === m && p.startsWith(pre)) return no(9109, 'Unauthorized to access requested resource', 403); }
    const json = body ? JSON.parse(body) : null;
    let m;
    if (p === '/zones' && req.method === 'GET') return ok(u.searchParams.get('name') === 'carmacars.ca' ? [{ id: 'z1', name: 'carmacars.ca' }] : []);
    if (p === '/zones/z1/dns_records' && req.method === 'GET') {
      let r = W.records;
      if (u.searchParams.get('name')) r = r.filter((x) => x.name === u.searchParams.get('name'));
      if (u.searchParams.get('type')) r = r.filter((x) => x.type === u.searchParams.get('type'));
      if (u.searchParams.get('proxied')) r = r.filter((x) => x.proxied);
      return ok(r);
    }
    if (p === '/zones/z1/dns_records' && req.method === 'POST') {
      if (W.domains.some((d) => d.hostname === json.name)) return no(81053, 'An A, AAAA, or CNAME record with that host already exists');
      const rec = { id: `r${++W.n}`, ...json }; W.records.push(rec); return ok(rec);
    }
    if ((m = /^\/zones\/z1\/dns_records\/(\w+)$/.exec(p))) {
      const i = W.records.findIndex((x) => x.id === m[1]);
      if (i < 0) return no(81044, 'Record does not exist', 404);
      if (req.method === 'DELETE') { W.records.splice(i, 1); return ok({ id: m[1] }); }
      if (req.method === 'PATCH') { Object.assign(W.records[i], json); return ok(W.records[i]); }
    }
    if ((m = /^\/zones\/z1\/settings\/(\w+)$/.exec(p))) {
      if (req.method === 'GET') return ok({ id: m[1], value: W.settings[m[1]] });
      W.settings[m[1]] = json.value; return ok({ id: m[1], value: json.value });
    }
    if (p === '/zones/z1/managed_headers') {
      if (req.method === 'GET') return ok({ managed_request_headers: [{ id: 'add_visitor_location_headers', enabled: W.location }], managed_response_headers: [] });
      W.location = json.managed_request_headers.find((x) => x.id === 'add_visitor_location_headers')?.enabled ?? W.location; return ok({});
    }
    if (p === '/accounts/acc/workers/domains' && req.method === 'GET') return ok(W.domains);
    if (p === '/accounts/acc/workers/domains' && req.method === 'PUT') {
      if (W.records.some((r) => r.name === json.hostname && ['A', 'AAAA', 'CNAME'].includes(r.type))) return no(100117, 'Hostname already has externally managed DNS records');
      const d = { id: `d${++W.n}`, hostname: json.hostname, service: json.service }; W.domains.push(d); return ok(d);
    }
    if ((m = /^\/accounts\/acc\/workers\/domains\/(\w+)$/.exec(p)) && req.method === 'DELETE') { W.domains = W.domains.filter((d) => d.id !== m[1]); return ok(null); }
    if (p === '/zones/z1/workers/routes' && req.method === 'GET') return ok(W.routes);
    if ((m = /^\/zones\/z1\/workers\/routes\/(\w+)$/.exec(p)) && req.method === 'DELETE') { W.routes = W.routes.filter((r) => r.id !== m[1]); return ok({ id: m[1] }); }
    if (p === '/accounts/acc/workers/scripts/carmacars-prod/schedules') {
      if (req.method === 'GET') return ok({ schedules: W.crons });
      W.crons = json; return ok({ schedules: json });
    }
    if (p === '/certificates' && req.method === 'POST') { W.certs++; return ok({ id: 'c1', certificate: sign(json.csr, json.hostnames, W.certDays) }); }
    return no(7003, `no route ${req.method} ${p}`, 404);
  });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const API = `http://127.0.0.1:${server.address().port}/client/v4`;
test.after(() => { server.close(); fs.rmSync(tmp, { recursive: true, force: true }); });

// async: the stand-in API runs in this process, so the script must not block the event loop (spawnSync would)
function run(args, extra = {}) {
  const env = { PATH: process.env.PATH, HOME: process.env.HOME ?? tmp, CF_API: API, CLOUDFLARE_API_TOKEN: 't', CLOUDFLARE_ACCOUNT_ID: 'acc', DOMAIN: 'carmacars.ca', DEPLOY_HOST: IP, ...extra };
  return new Promise((resolve) => {
    const c = spawn('bash', [SCRIPT, ...args], { env });
    let out = '', err = '';
    c.stdout.on('data', (d) => { out += d; });
    c.stderr.on('data', (d) => { err += d; });
    c.on('close', (code) => resolve({ code, out: out.trim(), err }));
  });
}
const site = (n) => W.records.filter((r) => r.name === n && ['A', 'AAAA', 'CNAME'].includes(r.type));

test('A: the new record, location headers and SSL Full (strict), twice with the same result', async () => {
  W = world();
  for (let i = 0; i < 2; i++) {
    const r = await run(['prepare']);
    assert.equal(r.code, 0, r.err);
    assert.deepEqual(site('new.carmacars.ca').map((x) => [x.type, x.content, x.proxied]), [['A', IP, true]]);
    assert.equal(W.location, true);
    assert.equal(W.settings.ssl, 'strict');
    assert.equal(W.settings.always_use_https, 'on', 'Always Use HTTPS is left alone (the Origin CA certificate needs nothing from it)');
    assert.equal(W.records.filter((x) => x.type === 'MX').length, 1);
  }
});

test('the Origin CA certificate: made once, then reused while it covers the domain', async () => {
  W = world();
  const dir = path.join(tmp, 'o1');
  const a = await run(['origin-cert', dir]);
  assert.equal(a.out, 'new', a.err);
  assert.equal(W.certs, 1);
  const pub = (args) => execFileSync('openssl', args, { encoding: 'utf8' });
  assert.equal(pub(['x509', '-in', `${dir}/cert.pem`, '-noout', '-pubkey']), pub(['pkey', '-in', `${dir}/key.pem`, '-pubout']), 'the key matches the certificate');
  assert.equal((fs.statSync(`${dir}/key.pem`).mode & 0o777).toString(8), '600');
  const b = await run(['origin-cert', path.join(tmp, 'o2'), `${dir}/cert.pem`]);
  assert.equal(b.out, 'reuse', b.err);
  assert.equal(W.certs, 1);
  // a certificate about to end is replaced
  W.certDays = 10;
  await run(['origin-cert', path.join(tmp, 'o3')]);
  W.certDays = 5475;
  assert.equal((await run(['origin-cert', path.join(tmp, 'o4'), path.join(tmp, 'o3', 'cert.pem')])).out, 'new');
});

test('a token without SSL and Certificates permission: none, the permission named, the run goes on', async () => {
  W = world();
  W.deny.add('POST /certificates');
  const r = await run(['origin-cert', path.join(tmp, 'o5')]);
  assert.equal(r.code, 0);
  assert.equal(r.out, 'none');
  assert.match(r.err, /Zone > SSL and Certificates > Edit/);
  assert.ok(!fs.existsSync(path.join(tmp, 'o5', 'key.pem')), 'no stray key is left');
});

test('B: the Worker loses its cron and its domains, the apex and www point at the server; again changes nothing; the rollback restores it', async () => {
  W = world();
  const envf = path.join(tmp, 'genv');
  fs.writeFileSync(envf, '');
  for (let i = 0; i < 2; i++) {
    const r = await run(['switch'], { GITHUB_ENV: envf });
    assert.equal(r.code, 0, r.err);
    assert.deepEqual(W.crons, []);
    assert.deepEqual(W.domains.map((d) => d.hostname), ['shop.carmacars.ca'], 'another Worker keeps its domain');
    assert.deepEqual(W.routes.map((r) => r.pattern), ['blog.carmacars.ca/*'], 'other routes stay');
    for (const h of ['carmacars.ca', 'www.carmacars.ca']) assert.deepEqual(site(h).map((x) => [x.type, x.content, x.proxied]), [['A', IP, true]]);
  }
  assert.match(fs.readFileSync(envf, 'utf8'), /CF_WORKER_CRON=off/);
  assert.equal((await run(['live-on'])).out, 'vps');
  const back = await run(['unswitch']);
  assert.equal(back.code, 0, back.err);
  assert.deepEqual(site('carmacars.ca'), []);
  assert.deepEqual(W.domains.map((d) => d.hostname).sort(), ['carmacars.ca', 'shop.carmacars.ca', 'www.carmacars.ca']);
  assert.deepEqual(W.crons, [{ cron: '* * * * *' }]);
  assert.equal((await run(['live-on'])).out, 'worker');
});

test('B without Workers permission: the cron stays, CF_WORKER_CRON=on (the server keeps its cron off), the permission named', async () => {
  W = world();
  W.deny.add('PUT /accounts/acc/workers/scripts');
  W.deny.add('DELETE /accounts/acc/workers/domains');
  const envf = path.join(tmp, 'genv2');
  fs.writeFileSync(envf, '');
  const r = await run(['switch'], { GITHUB_ENV: envf });
  assert.equal(r.code, 0);
  assert.match(fs.readFileSync(envf, 'utf8'), /CF_WORKER_CRON=on/);
  assert.match(r.err, /Account > Workers Scripts > Edit/);
  assert.deepEqual(W.crons, [{ cron: '* * * * *' }]);
});

test('live-on: the input wins, then the variable; an unreadable zone fails', async () => {
  W = world();
  assert.equal((await run(['live-on'], { WEB_LIVE_ON_INPUT: 'vps' })).out, 'vps');
  assert.equal((await run(['live-on'], { WEB_LIVE_ON_VAR: 'vps' })).out, 'vps');
  assert.equal((await run(['live-on'])).out, 'worker');
  W.deny.add('GET /zones');
  assert.notEqual((await run(['live-on'])).code, 0);
});
