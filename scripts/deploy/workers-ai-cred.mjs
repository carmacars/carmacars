#!/usr/bin/env node
// r48 part AI (docs/hosting/off-cloudflare.md, section 2.2): the Workers AI credentials the company's server gets, with no
// new secret. Run by deploy-vps (Settings step) before web.env is written:
//   node scripts/deploy/workers-ai-cred.mjs <out.json>
// Reads CLOUDFLARE_ACCOUNT_ID, WORKERS_AI_API_TOKEN (optional secret) and CLOUDFLARE_API_TOKEN (the CI token wrangler uses).
// Tries, in order, and keeps the first token that may run Workers AI (one cheap probe call each, a 1B model, one token out):
//   1. WORKERS_AI_API_TOKEN, when that secret exists
//   2. a token made now by the CI token with Workers AI Read only (account API tokens; needs Account > Account API Tokens >
//      Edit on the CI token). The server then holds a token that can do nothing else; the two newest of that name are kept
//   The CI token itself is NEVER written to the server (it may also edit DNS and Workers). Without 1 or 2 the server has no
//   Workers AI and runs on its local models; the job summary names the permission to add.
// Writes {token, source, probe, message} to <out.json> (mode 600) and prints GitHub annotations; the token is masked first.
// probe: ok | allowance_used (the token may run Workers AI; today's free neurons are used) | no_permission | error | none.
// Never fails the deploy: without a working token the server's chain uses its local models and Gemini.
import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const API = 'https://api.cloudflare.com/client/v4';
export const PROBE_MODEL = '@cf/meta/llama-3.2-1b-instruct';
export const TOKEN_NAME = 'carmacars-server-workers-ai';
export const PERMISSION = 'Workers AI Read';
const NEED = `Add the permission "Account > Account API Tokens > Edit" to the CLOUDFLARE_API_TOKEN secret's token (Cloudflare > My Profile > API Tokens > edit) so the job can make a "${PERMISSION}" token for the server, or add a WORKERS_AI_API_TOKEN secret with "Account > ${PERMISSION}"`;

/** One cheap Workers AI call with a token: what it says about the token. */
export async function probe(account, token, f = fetch) {
  try {
    const r = await f(`${API}/accounts/${encodeURIComponent(account)}/ai/run/${PROBE_MODEL}`, {
      method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ messages: [{ role: 'user', content: 'Say OK.' }], max_tokens: 1 })
    });
    const j = await r.json().catch(() => null);
    const errs = (j?.errors ?? []).map((e) => `${e.code ?? ''} ${e.message ?? ''}`.trim()).join('; ');
    if (r.ok && j?.success !== false) return { probe: 'ok', detail: '' };
    if (/4006|neuron|allocation/i.test(errs)) return { probe: 'allowance_used', detail: errs };
    if (r.status === 401 || r.status === 403 || /\b(10000|9109|10001)\b|authenticat|not authorized|permission/i.test(errs)) return { probe: 'no_permission', detail: errs || `HTTP ${r.status}` };
    return { probe: 'error', detail: errs || `HTTP ${r.status}` };
  } catch (e) {
    return { probe: 'error', detail: e instanceof Error ? e.message : String(e) };
  }
}

const works = (p) => p.probe === 'ok' || p.probe === 'allowance_used';

/** A token with Workers AI Read only, made by the CI token; null when the CI token may not make tokens. */
export async function mint(account, ciToken, f = fetch) {
  const h = { authorization: `Bearer ${ciToken}`, 'content-type': 'application/json' };
  try {
    const g = await f(`${API}/accounts/${encodeURIComponent(account)}/tokens/permission_groups`, { headers: h });
    const gj = await g.json().catch(() => null);
    const group = (gj?.result ?? []).find((x) => x?.name === PERMISSION);
    if (!g.ok || !group?.id) return null;
    const r = await f(`${API}/accounts/${encodeURIComponent(account)}/tokens`, {
      method: 'POST', headers: h,
      body: JSON.stringify({ name: TOKEN_NAME, policies: [{ effect: 'allow', resources: { [`com.cloudflare.api.account.${account}`]: '*' }, permission_groups: [{ id: group.id }] }] })
    });
    const rj = await r.json().catch(() => null);
    const value = rj?.result?.value;
    if (!r.ok || typeof value !== 'string' || !value) return null;
    // the older ones of that name: the newest two stay (the one the running server holds until the new image starts)
    const l = await f(`${API}/accounts/${encodeURIComponent(account)}/tokens?per_page=50`, { headers: h }).then((x) => x.json()).catch(() => null);
    const mine = (l?.result ?? []).filter((t) => t?.name === TOKEN_NAME && t.id).sort((a, b) => String(b.issued_on ?? '').localeCompare(String(a.issued_on ?? '')));
    for (const old of mine.slice(2)) await f(`${API}/accounts/${encodeURIComponent(account)}/tokens/${encodeURIComponent(old.id)}`, { method: 'DELETE', headers: h }).catch(() => undefined);
    return value;
  } catch {
    return null;
  }
}

/** The credentials for the server: the first token that may run Workers AI. */
export async function choose(env, f = fetch) {
  const account = (env.CLOUDFLARE_ACCOUNT_ID ?? '').trim();
  const secret = (env.WORKERS_AI_API_TOKEN ?? '').trim();
  const ci = (env.CLOUDFLARE_API_TOKEN ?? '').trim();
  if (!account || (!secret && !ci)) return { token: '', source: 'none', probe: 'none', message: 'No CLOUDFLARE_ACCOUNT_ID or no Cloudflare token in this job: Workers AI is off on the server (its local models and Gemini answer)' };
  const notes = [];
  if (secret) {
    const p = await probe(account, secret, f);
    if (works(p)) return { token: secret, source: 'secret', probe: p.probe, message: 'Workers AI: the WORKERS_AI_API_TOKEN secret' };
    notes.push(`the WORKERS_AI_API_TOKEN secret cannot run Workers AI (${p.detail})`);
  }
  if (ci) {
    const pc = await probe(account, ci, f);
    if (works(pc)) {
      const minted = await mint(account, ci, f);
      if (minted) {
        const pm = await probe(account, minted, f);
        if (works(pm)) return { token: minted, source: 'minted', probe: pm.probe, message: `Workers AI: a token with ${PERMISSION} only, made by the CI token (the server holds nothing else)` };
      }
      // the CI token itself is never written to the server (it may edit DNS and Workers): no minted token, no Workers AI
      notes.push(minted ? 'the token made by the CI token could not run Workers AI' : `the CI token may not make tokens (it needs Account > Account API Tokens > Edit)`);
    }
    notes.push(pc.probe === 'no_permission' ? `the CI token has no Workers AI permission (${pc.detail})` : `the CI token's Workers AI probe failed (${pc.detail})`);
  }
  return { token: '', source: 'none', probe: notes.some((n) => /permission/.test(n)) ? 'no_permission' : 'error', message: `Workers AI is off on the server: ${notes.join('; ')}. ${NEED}. Until then the server's local models and Gemini answer` };
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const out = process.argv[2];
  if (!out) { console.error('usage: workers-ai-cred.mjs <out.json>'); process.exit(2); }
  const r = await choose(process.env);
  if (r.token && process.env.GITHUB_ACTIONS) console.log(`::add-mask::${r.token}`);
  writeFileSync(out, JSON.stringify(r), { mode: 0o600 });
  const level = r.token ? 'notice' : 'warning';
  const line = `${r.message} (probe: ${r.probe})`;
  console.log(process.env.GITHUB_ACTIONS ? `::${level} title=Workers AI::${line}` : line);
}
