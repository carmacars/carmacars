#!/usr/bin/env node
// The one-off owner terms audit of release 48 (part MR, migrations 3100 and 3110): every program owner's car, its terms
// in force today (management fee, Insurance Fee, where its Fees are paid from) against the terms agreed with the owner
// (owner_terms_agreed, from the owner's notes), with each mismatch named. Read only, unless --fix: then, as an Admin,
// every mismatch is corrected from the car's start (app.owner_terms_audit_fix: versioned corrections, the owner signs an
// updated Vehicle Schedule only when they get less) and the audit is printed again. A management fee not in the notes
// is never changed, only flagged.
//
//   DATABASE_URL=postgres://... node scripts/owner-terms-audit.mjs [--json] [--fix --admin <user id>]
import postgres from 'postgres';

const args = process.argv.slice(2);
const opt = (k) => { const i = args.indexOf(`--${k}`); return i >= 0 ? args[i + 1] ?? null : null; };
const url = process.env.DATABASE_URL;
if (!url) { console.error('Set DATABASE_URL'); process.exit(2); }
const sql = postgres(url, { max: 1, onnotice: () => {} });
const pct = (bps) => (bps === null || bps === undefined ? '-' : `${Number(bps) / 100}%`);
const usd = (c) => (c === null || c === undefined ? '-' : `$${(Number(c) / 100).toFixed(2)}`);

async function audit() {
  return sql`select owner, car, plate, revenue_share_bps, agreed_share_bps, insurance_fee_cents, agreed_insurance_cents, fees_paid_from,
                    agreed_costs_from_earnings, shareholder, effective_from, status, flags from app.owner_terms_audit()`;
}
function print(rows) {
  if (args.includes('--json')) { process.stdout.write(`${JSON.stringify(rows, null, 2)}\n`); return; }
  const out = rows.map((r) => ({ owner: r.owner, car: `${r.car}${r.plate ? ` (${r.plate})` : ''}`, fee: `${pct(r.revenue_share_bps)} / agreed ${r.shareholder ? '90/10' : pct(r.agreed_share_bps)}`,
    insurance: `${usd(r.insurance_fee_cents)} / agreed ${usd(r.agreed_insurance_cents)}`, costs: `${r.fees_paid_from}${r.agreed_costs_from_earnings ? ' / agreed from earnings' : ''}`,
    status: r.status, flags: (r.flags ?? []).join('; ') }));
  console.table(out);
  const bad = rows.filter((r) => r.status === 'mismatch').length;
  process.stdout.write(`${rows.length} cars, ${bad} mismatched\n`);
}

try {
  print(await audit());
  if (args.includes('--fix')) {
    const admin = opt('admin');
    if (!admin) { console.error('--fix needs --admin <the Admin user id it is recorded as>'); process.exit(2); }
    const [r] = await sql`select app.owner_terms_audit_fix(${admin}::uuid) as r`;
    process.stdout.write(`fixed: ${JSON.stringify(r.r)}\n`);
    print(await audit());
  }
} finally { await sql.end(); }
