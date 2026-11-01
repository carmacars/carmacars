import 'server-only';
import { agreementPdf } from '@/features/agreement/pdf';
import type { Block } from '@/features/agreement/model';
import { HOW_IT_WORKS_AMOUNTS, howItWorksRow, investmentCalc } from './calc';
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
  if (multiplier) blocks.push({ t: 'p', text: `${multiplier}x multiplier on money invested in the fleet: the company's headline figure (internal, not audited, not a forecast and not a promise of any return).` });
  blocks.push({ t: 'table', head: ['The terms', ''], kv: true, rows: [
    ['Minimum investment', $(terms.min_cents)],
    ['Your return', `${pct(terms.offer_bps)} a year on our current offer, paid monthly. Each investor's rate is set in their own agreement.`],
    ['Lockup', `The first ${terms.lockup_months} months. No return accrues during the lockup.`],
    ['Your principal', 'Stays invested, with no fixed term. Keep it in, or reinvest your monthly returns.'],
    ['Getting your money out', 'Sell your investment to another investor, or have it bought back by the company.'],
    ['Company repayment', "The company can repay your investment at any time with 6 months' notice."],
    ['What it is', 'An investment, not a loan. Investors receive no shares in the company.'],
    ...(terms.company ? [['Who you invest with', terms.company] as [string, string]] : [])] });
  blocks.push({ t: 'table', head: ['Amount invested', 'Monthly payout', 'Paid by month 24', 'Paid by month 36'],
    rows: HOW_IT_WORKS_AMOUNTS.map((a) => { const x = howItWorksRow(a, terms.offer_bps / 10000, terms.lockup_months); return [$d(a), $d(x.monthly), $d(x.by24), $d(x.by36)]; }) });
  const c = investmentCalc({ amount: m.calc.amount, start: m.calc.start, rate: m.calc.rate, lockupMonths: terms.lockup_months, reinvest: m.calc.reinvest });
  blocks.push({ t: 'h2', text: `Calculator: ${$d(m.calc.amount)} from ${longDate(m.calc.start)} at ${+(m.calc.rate * 100).toFixed(2)}%` });
  blocks.push({ t: 'table', head: ['Result', ''], kv: true, rows: [
    ['Monthly payout to you', $d(c.monthlyPayout)], ['Lockup ends', longDate(c.lockupEnds)], ['First monthly payment', longDate(c.firstPayment)],
    ['Total paid to you by month 36', $d(c.paidBy36)], ['Value at month 36', `${$d(c.value36)} (${c.multiple36.toFixed(2)}x)`]] });
  blocks.push({ t: 'p', text: 'For information only and not an offer by itself. The signed investment agreement governs. Like any investment, it carries risk.' });
  return blocks;
}

export async function investorModelPdf(m: InvestorModel, multiplier: number | null): Promise<Uint8Array> {
  return agreementPdf(investorModelBlocks(m, multiplier), { title: 'Your CarmaCars investment', createdAt: new Date(`${m.terms.today}T12:00:00Z`), brand: true, logo: null,
    footer: 'CarmaCars. Your investment sheets. Illustration only; your agreement and statements govern.' });
}
