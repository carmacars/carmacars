import 'server-only';
import { door } from '@/server/door';
import { myInvestment, type MineSummary } from '@/features/investor-model/mine';
import type { InvestorHome, ReturnRow } from '@/features/investor/plan';
import { firstOfNextMonth } from '@/features/deck/returns';

// The investor's sheets (migration 0420): their own investments and statements (investor_read home and statements, their
// rows only) and the terms the calculators need (investor_read model_terms). Three small reads, no fleet figure among them.
export interface ModelTerms { legal_name: string; min_cents: number; lockup_months: number; payment_day: number; offer_bps: number; multiplier: number | string | null; company: string | null; sheet_daily_rate_cents?: number | null; today: string }
export interface InvestorModel { terms: ModelTerms; home: InvestorHome; rows: ReturnRow[]; mine: MineSummary;
  calc: { amount: number; start: string; rate: number; reinvest: boolean } }

export async function loadInvestorModel(userId: string, reinvest?: boolean): Promise<InvestorModel> {
  const [terms, home, rows] = await Promise.all([
    door<ModelTerms>(userId, 'investor_read', 'model_terms'),
    door<InvestorHome>(userId, 'investor_read', 'home'),
    door<ReturnRow[]>(userId, 'investor_read', 'statements').catch(() => [] as ReturnRow[])
  ]);
  const mine = myInvestment(home.investments, rows, terms.today, { reinvest, payDay: terms.payment_day });
  // the calculator starts from their own numbers: what they invested, when, at their rate (else the minimum, next month, the offer)
  const amount = mine.investedCents > 0 ? Math.round(mine.investedCents / 100) : Math.max(50_000, Math.round(terms.min_cents / 100));
  return { terms, home, rows, mine,
    calc: { amount, start: mine.startDate ?? firstOfNextMonth(terms.today), rate: (mine.yearlyBps ?? terms.offer_bps ?? 1000) / 10000, reinvest: mine.reinvest } };
}

export const multiplierOf = (t: Pick<ModelTerms, 'multiplier'>) => { const n = Number(t.multiplier); return Number.isFinite(n) && n > 0 ? n : null; };
