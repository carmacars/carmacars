import { currentUser } from '@/server/portal/data';
import { rolesOf } from '@/server/door';
import { loadInvestorModel, multiplierOf } from '@/server/investor-model';
import { investorWorkbook } from '@/features/investor-model/workbook';
import { XLSX_TYPE } from '@/lib/xlsx';

// "Download as Excel" on the investor's sheets (migration 0420): a fresh .xlsx built for this investor on each download, with
// the investor-safe tabs only (My investment, How it works, Investment calculator, Fund a car) and working formulas. Made
// in the Worker with the dependency-free writer (src/lib/xlsx.ts): no library, a few milliseconds of CPU.
export const dynamic = 'force-dynamic';

export async function GET(req: Request) {
  const user = await currentUser();
  if (!user) return Response.redirect(new URL('/sign-in?next=/investor/model', req.url), 302);
  if (!(await rolesOf(user.id)).investor) return new Response('Not found', { status: 404 });
  const r = new URL(req.url).searchParams.get('reinvest');
  const m = await loadInvestorModel(user.id, r === '1' ? true : r === '0' ? false : undefined);
  const wb = investorWorkbook({ multiplier: multiplierOf(m.terms), rate: m.calc.rate, minimum: m.terms.min_cents / 100, lockupMonths: m.terms.lockup_months,
    amount: m.calc.amount, start: m.calc.start, reinvest: m.calc.reinvest, investorName: m.terms.legal_name, company: m.terms.company,
    mine: m.mine.rows.length || m.mine.investedCents ? m.mine : null, generatedOn: m.terms.today });
  return new Response(wb.bytes() as unknown as BodyInit, { headers: { 'content-type': XLSX_TYPE, 'content-disposition': `attachment; filename="CarmaCars-investment-${m.terms.today}.xlsx"`,
    'cache-control': 'private, no-store', 'x-robots-tag': 'noindex, nofollow', 'x-content-type-options': 'nosniff' } });
}
