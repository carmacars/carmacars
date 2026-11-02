import 'server-only';
import { door } from '@/server/door';
import { readInputs, runModel, type ActualMonth, type Inputs, type InvestorOnFile, type Model } from '@/features/finance-model/engine';

// Admin > Money > Company model (migration 0420): one read (admin_read finance_model, Admins only in the database), the
// actuals the hourly job stored, the saved assumptions, the investors on file; the forecast runs here, in a few
// milliseconds, from those rows. Nothing is aggregated on a page view.
export interface FinanceRead {
  actuals: ActualMonth[]; computed_at: string | null; inputs: unknown; updated_at: string | null; updated_by: string | null; investors: InvestorOnFile[];
  terms: { min_cents: number; lockup_months: number; payment_day: number; offer_bps: number | null; multiplier: number | string | null }; company: string | null; today: string;
}
export interface FinanceModel { read: FinanceRead; inputs: Inputs; model: Model }

export async function loadFinanceModel(adminId: string): Promise<FinanceModel> {
  const read = await door<FinanceRead>(adminId, 'admin_read', 'finance_model');
  const inputs = readInputs(read.inputs);
  return { read, inputs, model: runModel(read.actuals, inputs, read.investors) };
}
