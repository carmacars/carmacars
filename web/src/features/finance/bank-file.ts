// Release 49 (3480): reads a bank download in the browser, so the file itself never leaves the person's computer; only its
// lines go to the database (app.bank_import), which keeps each one once and matches it. Pure: unit tested
// (bank-file.test.ts). docs/finance/bank-data.md has the formats:
//   RBC classic CSV:  Account Type, Account Number, Transaction Date, Cheque Number, Description 1, Description 2, CAD$, USD$
//                     (M/D/YYYY, one signed amount per currency, negative is money out)
//   RBC Edge / other: Date, Description, Debit, Credit (or Withdrawals / Deposits, or one Amount), Balance
//   OFX / QFX:        STMTTRN blocks (DTPOSTED, TRNAMT, FITID, NAME, MEMO, CHECKNUM), ACCTID, CURDEF, LEDGERBAL
// Only the last four digits of the account number leave this module, with a SHA-256 of the full number (to recognise the
// account next time).

export interface BankLine { posted_on: string; amount_cents: number; description: string; cheque_number: string | null; fit_id: string | null; balance_cents: number | null }
export interface BankFile {
  format: 'rbc_csv' | 'csv' | 'ofx';
  accounts: Array<{ last4: string | null; number: string | null; currency: 'CAD' | 'USD'; lines: BankLine[]; balance_cents: number | null; balance_on: string | null }>;
  warnings: string[];
}

/** RFC 4180 rows: quoted cells, doubled quotes, CRLF or LF; blank rows dropped. */
export function csvRows(text: string): string[][] {
  const out: string[][] = []; let row: string[] = []; let cell = ''; let q = false;
  const s = text.replace(/^﻿/, '');
  for (let i = 0; i < s.length; i++) {
    const c = s[i]!;
    if (q) { if (c === '"' && s[i + 1] === '"') { cell += '"'; i++; } else if (c === '"') q = false; else cell += c; continue; }
    if (c === '"') q = true;
    else if (c === ',') { row.push(cell); cell = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && s[i + 1] === '\n') i++; row.push(cell); cell = ''; if (row.some((x) => x.trim())) out.push(row); row = []; }
    else cell += c;
  }
  row.push(cell); if (row.some((x) => x.trim())) out.push(row);
  return out;
}

/** "$1,234.56", "-12.5", "(40.00)", "1 234,56"-free Canadian amounts to cents; null when it is not a number. */
export function cents(v: string | undefined | null): number | null {
  if (v === undefined || v === null) return null;
  let s = v.trim();
  if (!s) return null;
  let neg = false;
  if (/^\(.*\)$/.test(s)) { neg = true; s = s.slice(1, -1); }
  s = s.replace(/[$\s]|CAD|USD/gi, '').replace(/,/g, '');
  if (s.endsWith('-')) { neg = !neg; s = s.slice(0, -1); }
  if (s.startsWith('-')) { neg = !neg; s = s.slice(1); } else if (s.startsWith('+')) s = s.slice(1);
  if (!/^\d+(\.\d{1,2})?$/.test(s)) return null;
  const [w, f = ''] = s.split('.');
  const c = Number(w) * 100 + Number((f + '00').slice(0, 2));
  return neg ? -c : c;
}

const MONTHS: Record<string, number> = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12 };
const ymd = (y: number, m: number, d: number) => (y > 1900 && m >= 1 && m <= 12 && d >= 1 && d <= 31 ? `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}` : null);
/** A bank's date to YYYY-MM-DD: 2026-11-03, 11/3/2026 (RBC: month first), 3-Nov-2026, Nov 3, 2026, 20261103. */
export function isoDay(v: string | undefined | null): string | null {
  const s = (v ?? '').trim();
  let m = /^(\d{4})-(\d{1,2})-(\d{1,2})/.exec(s); if (m) return ymd(+m[1]!, +m[2]!, +m[3]!);
  m = /^(\d{4})(\d{2})(\d{2})/.exec(s); if (m) return ymd(+m[1]!, +m[2]!, +m[3]!);
  m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(s); if (m) return ymd(+m[3]!, +m[1]!, +m[2]!);
  m = /^(\d{1,2})[- ]([A-Za-z]{3})[a-z]*[- ,]+(\d{4})$/.exec(s); if (m && MONTHS[m[2]!.toLowerCase()]) return ymd(+m[3]!, MONTHS[m[2]!.toLowerCase()]!, +m[1]!);
  m = /^([A-Za-z]{3})[a-z]*\.? (\d{1,2}),? (\d{4})$/.exec(s); if (m && MONTHS[m[1]!.toLowerCase()]) return ymd(+m[3]!, MONTHS[m[1]!.toLowerCase()]!, +m[2]!);
  return null;
}

const tidy = (...parts: Array<string | undefined>) => parts.map((p) => (p ?? '').trim()).filter(Boolean).join(' ').replace(/\s+/g, ' ').slice(0, 300);
const digits = (v: string | null | undefined) => (v ?? '').replace(/\D/g, '');
const last4 = (v: string | null | undefined) => { const d = digits(v); return d.length >= 3 ? d.slice(-4) : null; };

function pick(h: string[], ...names: Array<string | RegExp>): number {
  for (const n of names) {
    const i = h.findIndex((x) => (typeof n === 'string' ? x === n : n.test(x)));
    if (i >= 0) return i;
  }
  return -1;
}

function fromCsv(text: string): BankFile {
  const rows = csvRows(text);
  const warnings: string[] = [];
  const hi = rows.findIndex((r) => r.some((c) => /date/i.test(c)) && r.some((c) => /(amount|debit|credit|withdraw|deposit|cad\$|usd\$)/i.test(c)));
  if (hi < 0) throw new Error('This file has no Date and Amount columns. Download the account\'s transactions as CSV (or OFX) from online banking.');
  const h = rows[hi]!.map((x) => x.trim().toLowerCase());
  const col = {
    acct: pick(h, 'account number', /account ?(no|#|number)/),
    date: pick(h, 'transaction date', 'posted date', 'posting date', 'date', /date/),
    chq: pick(h, 'cheque number', /cheque|check/),
    d1: pick(h, 'description 1', 'description', 'transaction description', 'details', 'payee', 'name', /description/),
    d2: pick(h, 'description 2', 'memo'),
    cad: pick(h, 'cad$', 'cad'),
    usd: pick(h, 'usd$', 'usd'),
    amount: pick(h, 'amount', 'transaction amount', /amount/),
    debit: pick(h, 'debit', 'withdrawals', 'withdrawal', /debit|withdraw|money out/),
    credit: pick(h, 'credit', 'deposits', 'deposit', /credit|deposit|money in/),
    bal: pick(h, 'balance', 'running balance', /balance/),
    cur: pick(h, 'currency')
  };
  const rbc = col.cad >= 0 || col.usd >= 0;
  type Acc = BankFile['accounts'][number];
  const by = new Map<string, Acc>();
  const acc = (num: string | null, cur: 'CAD' | 'USD') => {
    const k = `${digits(num)}|${cur}`;
    let a = by.get(k);
    if (!a) { a = { last4: last4(num), number: digits(num) || null, currency: cur, lines: [], balance_cents: null, balance_on: null }; by.set(k, a); }
    return a;
  };
  let skipped = 0;
  for (const r of rows.slice(hi + 1)) {
    const day = isoDay(r[col.date]);
    if (!day) { skipped++; continue; }
    const num = col.acct >= 0 ? (r[col.acct] ?? '') : null;
    const description = tidy(r[col.d1], col.d2 >= 0 ? r[col.d2] : undefined);
    const chq = col.chq >= 0 ? (r[col.chq] ?? '').trim() || null : null;
    const bal = col.bal >= 0 ? cents(r[col.bal]) : null;
    const amounts: Array<[number | null, 'CAD' | 'USD']> = [];
    if (rbc) {
      if (col.cad >= 0) amounts.push([cents(r[col.cad]), 'CAD']);
      if (col.usd >= 0) amounts.push([cents(r[col.usd]), 'USD']);
    } else {
      const cur = col.cur >= 0 && /usd/i.test(r[col.cur] ?? '') ? 'USD' : 'CAD';
      if (col.amount >= 0) amounts.push([cents(r[col.amount]), cur]);
      else {
        const dr = cents(r[col.debit]); const cr = cents(r[col.credit]);
        amounts.push([cr ? Math.abs(cr) : dr ? -Math.abs(dr) : null, cur]);
      }
    }
    const real = amounts.filter(([c]) => c !== null && c !== 0) as Array<[number, 'CAD' | 'USD']>;
    if (!real.length) { skipped++; continue; }
    for (const [c, cur] of real) acc(num, cur).lines.push({ posted_on: day, amount_cents: c, description, cheque_number: chq, fit_id: null, balance_cents: bal });
  }
  if (skipped) warnings.push(`${skipped} row(s) without a date or an amount were left out.`);
  const accounts = [...by.values()].filter((a) => a.lines.length);
  for (const a of accounts) {
    const withBal = a.lines.filter((l) => l.balance_cents !== null);
    if (withBal.length) {
      // the newest line's balance (files run oldest first or newest first: take the latest date, then the file's last row of it)
      const top = [...withBal].sort((x, y) => (x.posted_on < y.posted_on ? -1 : x.posted_on > y.posted_on ? 1 : 0)).pop()!;
      a.balance_cents = top.balance_cents; a.balance_on = top.posted_on;
    }
  }
  if (!accounts.length) throw new Error('No transactions found in this file.');
  return { format: rbc ? 'rbc_csv' : 'csv', accounts, warnings };
}

/** OFX 1.x (SGML, unclosed tags) and 2.x (XML): one value of a tag inside a block. */
const tag = (block: string, name: string) => { const m = new RegExp(`<${name}>([^<\\r\\n]*)`, 'i').exec(block); return m ? m[1]!.trim() : null; };
const decode = (s: string) => s.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;|&#39;/g, "'");

function fromOfx(text: string): BankFile {
  const warnings: string[] = [];
  const stmts = text.split(/<STMTRS>|<CCSTMTRS>/i).slice(1);
  if (!stmts.length) throw new Error('This OFX file has no bank statement in it.');
  const accounts: BankFile['accounts'] = [];
  for (const st of stmts) {
    const cur = (tag(st, 'CURDEF') ?? 'CAD').toUpperCase() === 'USD' ? 'USD' : 'CAD';
    const num = tag(st, 'ACCTID');
    const lines: BankLine[] = [];
    for (const b of st.split(/<STMTTRN>/i).slice(1)) {
      const blk = b.split(/<\/STMTTRN>/i)[0]!;
      const day = isoDay(tag(blk, 'DTPOSTED'));
      const amt = cents(tag(blk, 'TRNAMT'));
      if (!day || !amt) continue;
      lines.push({ posted_on: day, amount_cents: amt, description: tidy(decode(tag(blk, 'NAME') ?? ''), decode(tag(blk, 'MEMO') ?? '')),
        cheque_number: tag(blk, 'CHECKNUM'), fit_id: tag(blk, 'FITID'), balance_cents: null });
    }
    const lb = st.split(/<LEDGERBAL>/i)[1] ?? '';
    accounts.push({ last4: last4(num), number: digits(num) || null, currency: cur, lines,
      balance_cents: lb ? cents(tag(lb, 'BALAMT')) : null, balance_on: lb ? isoDay(tag(lb, 'DTASOF')) : null });
  }
  const withLines = accounts.filter((a) => a.lines.length || a.balance_cents !== null);
  if (!withLines.length) throw new Error('No transactions found in this file.');
  return { format: 'ofx', accounts: withLines, warnings };
}

/** Reads a CSV or OFX/QFX download. Throws an Error whose message is shown to the person as written. */
export function readBankFile(text: string): BankFile {
  if (/<OFX>|OFXHEADER/i.test(text.slice(0, 2000))) return fromOfx(text);
  return fromCsv(text);
}

/** SHA-256 hex of a text, in the browser or on the server (Web Crypto). */
export async function sha256Hex(s: string): Promise<string> {
  const b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, '0')).join('');
}

/** What the database takes for one account of the file (app.bank_import): the full number only as its hash. */
export async function importPayload(f: BankFile, i: number, fileText: string, fileName: string, extra: { account_id?: string | null; balance_cents?: number | null; balance_on?: string | null; nickname?: string | null } = {}) {
  const a = f.accounts[i]!;
  const typed = extra.balance_cents !== undefined && extra.balance_cents !== null;
  return {
    account: extra.account_id ? { id: extra.account_id } : { last4: a.last4, hash: a.number ? await sha256Hex(`rbc:${a.number}`) : null, currency: a.currency, nickname: extra.nickname ?? null },
    source: f.format === 'ofx' ? 'ofx' : 'csv',
    file_name: fileName.slice(0, 200),
    // one hash per account of the file, so a file with two accounts imports both
    file_sha256: await sha256Hex(`${i}:${a.currency}:${fileText}`),
    balance_cents: typed ? extra.balance_cents : a.balance_cents,
    balance_on: typed ? (extra.balance_on ?? null) : a.balance_on,
    balance_source: typed ? 'typed' : f.format === 'ofx' ? 'ofx' : 'csv',
    lines: a.lines
  };
}

/** The money in and out of a set of lines, for the preview before importing. */
export function totals(lines: BankLine[]) {
  let inn = 0, out = 0; let from: string | null = null, to: string | null = null;
  for (const l of lines) {
    if (l.amount_cents > 0) inn += l.amount_cents; else out -= l.amount_cents;
    if (!from || l.posted_on < from) from = l.posted_on;
    if (!to || l.posted_on > to) to = l.posted_on;
  }
  return { in_cents: inn, out_cents: out, from, to, count: lines.length };
}
