import { currentUser } from '@/server/portal/data';
import { rolesOf } from '@/server/door';
import { loadInvestorModel, multiplierOf } from '@/server/investor-model';
import { investorModelPdf } from '@/features/investor-model/pdf';

// "Download as PDF" on the investor's sheets (migration 0420): their investment, the schedule and how it works, laid out
// with the same pdf-lib renderer as the agreements and statements.
export const dynamic = 'force-dynamic';

export async function GET(req: Request) {
  const user = await currentUser();
  if (!user) return Response.redirect(new URL('/sign-in?next=/investor/model', req.url), 302);
  if (!(await rolesOf(user.id)).investor) return new Response('Not found', { status: 404 });
  const r = new URL(req.url).searchParams.get('reinvest');
  const m = await loadInvestorModel(user.id, r === '1' ? true : r === '0' ? false : undefined);
  const bytes = await investorModelPdf(m, multiplierOf(m.terms));
  return new Response(bytes as unknown as BodyInit, { headers: { 'content-type': 'application/pdf', 'content-disposition': `attachment; filename="CarmaCars-investment-${m.terms.today}.pdf"`,
    'cache-control': 'private, no-store', 'x-robots-tag': 'noindex, nofollow', 'x-content-type-options': 'nosniff' } });
}
