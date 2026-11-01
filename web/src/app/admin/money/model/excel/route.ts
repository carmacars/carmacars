import { assertAdmin } from '@/server/admin/data';
import { loadFinanceModel } from '@/server/finance-model';
import { internalWorkbook } from '@/features/finance-model/workbook';
import { XLSX_TYPE } from '@/lib/xlsx';

// "Download as Excel" on Admin > Money > Company model (migration 0420): the full internal workbook, built fresh: the
// investor-safe tabs, the Assumptions (as saved), the Actuals (from the summary table) and the Forecast and Pro forma as
// live formulas over them. Admins only, here and in the database (admin_read finance_model).
export const dynamic = 'force-dynamic';

export async function GET(req: Request) {
  let admin;
  try { admin = await assertAdmin(); } catch { return Response.redirect(new URL('/admin/no-access', req.url), 302); }
  const { read, inputs, model } = await loadFinanceModel(admin.id);
  const n = Number(read.terms.multiplier);
  const wb = internalWorkbook({ actuals: read.actuals, inputs, investors: read.investors, model, multiplier: Number.isFinite(n) && n > 0 ? n : null,
    offerRate: (read.terms.offer_bps ?? 3000) / 10000, minimum: read.terms.min_cents / 100, lockupMonths: read.terms.lockup_months, company: read.company,
    generatedOn: read.today, computedAt: read.computed_at });
  return new Response(wb.bytes() as unknown as BodyInit, { headers: { 'content-type': XLSX_TYPE, 'content-disposition': `attachment; filename="CarmaCars-company-model-INTERNAL-${read.today}.xlsx"`,
    'cache-control': 'private, no-store', 'x-robots-tag': 'noindex, nofollow', 'x-content-type-options': 'nosniff' } });
}
