import 'server-only';
import { agreementPdf } from '@/features/agreement/pdf';
import type { Block } from '@/features/agreement/model';
import { investmentCalc } from './calc';
import { EXAMPLE_AMOUNTS, FOOTNOTES, RAISE, TERMS, optionOneRow } from '../deck/pitch';
import { longDate, monthLabel } from '../deck/returns';
import type { InvestorModel } from '@/server/investor-model';

// The investor's sheets as a PDF: their investment and schedule (from their records), the terms in plain words and the
// calculator's example on their own numbers. Only investor-safe facts, as on the page.
const $ = (cents: number) => `$${(cents / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const $d = (dollars: number) => $(Math.round(dollars * 100));
const STATE: Record<string, string> = { paid: 'Paid', to_be_paid: 'To be paid', held: 'On hold', reinvested: 'Reinvested', projected: 'Projected' };

export function investorModelBlocks(m: InvestorModel, multiplier: number | null): Block[] {
  const { mine, terms } = m;
  const pct = (bps: number) => `${+(bps / 100).toFixed(2)}%`;
  const blocks: Block[] = [{ t: 'title', text: 'Your CarmaCars investment' }, { t: 'p', text: `${terms.legal_name}. From your records on ${longDate(terms.today)}.` }];
  if (mine.investedCents > 0 || mine.rows.length) {
    blocks.push({ t: 'table', head: ['Your investment', ''], kv: true, rows: [
      ['Invested Amount', $(mine.investedCents)], ['Start date', mine.startDate ? longDate(mine.startDate) : 'Not set'],
      ['Yearly Percentage', mine.yearlyBps !== null ? pct(mine.yearlyBps) : 'Not set'], ['Lockup ends', mine.lockupEnd ? longDate(mine.lockupEnd) : 'Not set'],
      ['Payouts made', `${$(mine.payoutsMadeCents)} (${mine.payoutsMadeCount} ${mine.payoutsMadeCount === 1 ? 'payment' : 'payments'})`],
      [mine.next?.mode === 'reinvest' ? 'Next Return' : 'Next payout', mine.next ? `${$(mine.next.cents)} on ${longDate(mine.next.date)}${mine.next.estimated ? ' (estimated)' : ''}` : 'After your lockup']] });
    blocks.push({ t: 'h2', text: `Your schedule (${mine.reinvest ? 'Returns reinvested' : 'Returns paid monthly'} from here on)` });
    blocks.push({ t: 'table', head: ['Return Month', 'Paid or added on', 'Invested at start', 'Return', 'Status'],
      rows: mine.rows.map((x) => [monthLabel(x.month), longDate(x.date), $(x.openingCents), $(x.returnCents), STATE[x.state] ?? x.state]) });
    blocks.push({ t: 'p', text: 'Projected rows use your Invested Amount and Yearly Percentage today, as your agreement computes a Return. Your monthly statement is the record.' });
  } else {
    blocks.push({ t: 'p', text: 'Your investment appears here once your agreement is signed and your funds have cleared.' });
  }
  blocks.push({ t: 'h2', text: 'How it works' });
  // r35: the terms of the 2026 deck (features/deck/pitch.ts), the same as every investor page
  if (multiplier) blocks.push({ t: 'p', text: `${multiplier}x multiplier on money invested in the fleet: CarmaCars' figure. ${FOOTNOTES.internal} Not a forecast and not a promise of any return.` });
  blocks.push({ t: 'table', head: ['The terms', ''], kv: true, rows: TERMS.map(([k, v]) => [k, v] as [string, string]) });
  blocks.push({ t: 'table', head: ['Amount invested', `Monthly at ${RAISE.option1.lowPct}%`, `Monthly at ${RAISE.option1.highPct}%`, `Yearly at ${RAISE.option1.lowPct}%`, `Yearly at ${RAISE.option1.highPct}%`],
    rows: EXAMPLE_AMOUNTS.map((a) => { const x = optionOneRow(a); return [$d(a), $d(x.monthlyLow), $d(x.monthlyHigh), $d(x.yearlyLow), $d(x.yearlyHigh)]; }) });
  const c = investmentCalc({ amount: m.calc.amount, start: m.calc.start, rate: m.calc.rate, lockupMonths: terms.lockup_months, reinvest: m.calc.reinvest });
  blocks.push({ t: 'h2', text: `Calculator: ${$d(m.calc.amount)} from ${longDate(m.calc.start)} at ${+(m.calc.rate * 100).toFixed(2)}%` });
  blocks.push({ t: 'table', head: ['Result', ''], kv: true, rows: [
    ['Monthly payout to you', $d(c.monthlyPayout)], ['Lockup ends', longDate(c.lockupEnds)], ['First monthly payment', longDate(c.firstPayment)],
    ['Total paid to you by month 36', $d(c.paidBy36)], ['Value at month 36', `${$d(c.value36)} (${c.multiple36.toFixed(2)}x)`]] });
  blocks.push({ t: 'p', text: `For information only and not an offer by itself. ${FOOTNOTES.offer}. Like any investment, it carries risk.` });
  return blocks;
}

export async function investorModelPdf(m: InvestorModel, multiplier: number | null): Promise<Uint8Array> {
  return agreementPdf(investorModelBlocks(m, multiplier), { title: 'Your CarmaCars investment', createdAt: new Date(`${m.terms.today}T12:00:00Z`), brand: true, logo: null,
    footer: 'CarmaCars. Your investment sheets. Illustration only; your agreement and statements govern.' });
}
