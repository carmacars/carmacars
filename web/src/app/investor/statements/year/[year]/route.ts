import { currentUser } from '@/server/portal/data';
import { door, rolesOf } from '@/server/door';
import { generatedFile } from '@/server/files';
import { zip } from '@/lib/zip';

// "Download all [year] statements" (07-investor.md section 2): a ZIP of the investor's own monthly statement
// PDFs of that year (each rendered once and stored, as from the statements page), with the yearly summary
// PDF for a past year and the summary table as CSV; ?format=csv gives the CSV alone. Only the signed-in
// investor's own rows come back from the door.
export const dynamic = 'force-dynamic';
type Row = { id: string; return_month: string; opening_invested_cents: number; days_earning: number; days_in_month: number; return_cents: number; disposition: string;
  payment_date: string; status: string; withheld_tax_cents?: number };
const dollars = (c: number) => (c / 100).toFixed(2);

export async function GET(req: Request, { params }: { params: Promise<{ year: string }> }) {
  const { year } = await params;
  if (!/^20\d\d$/.test(year)) return new Response('Not found', { status: 404 });
  const user = await currentUser();
  if (!user) return Response.redirect(new URL(`/sign-in?next=/investor/statements`, req.url), 302);
  if (!(await rolesOf(user.id)).investor) return new Response('Not found', { status: 404 });
  const [rows, home] = await Promise.all([door<Row[]>(user.id, 'investor_read', 'statements'), door<{ investor: { id: string } }>(user.id, 'investor_read', 'home')]);
  const mine = rows.filter((r) => r.return_month.startsWith(year)).sort((a, b) => a.return_month.localeCompare(b.return_month));
  const csv = ['Return Month,Opening Invested Amount,Days earning,Days in month,Return,Paid or reinvested,Payment Date,Status,Tax withheld',
    ...mine.map((r) => [r.return_month.slice(0, 7), dollars(r.opening_invested_cents), r.days_earning, r.days_in_month, dollars(r.return_cents),
      r.disposition === 'reinvest' ? 'Reinvested' : 'Paid', r.payment_date, r.status.replace(/_/g, ' '), dollars(r.withheld_tax_cents ?? 0)].join(','))].join('\r\n') + '\r\n';
  const headers = { 'cache-control': 'private, no-store', 'x-robots-tag': 'noindex, nofollow', 'x-content-type-options': 'nosniff' };
  if (new URL(req.url).searchParams.get('format') === 'csv') {
    return new Response(csv, { headers: { ...headers, 'content-type': 'text/csv; charset=utf-8', 'content-disposition': `attachment; filename="CarmaCars-returns-${year}.csv"` } });
  }
  if (!mine.length) return new Response('No statements for that year', { status: 404, headers });
  const files: Array<{ name: string; data: Uint8Array }> = [];
  for (const r of mine) {
    const f = await generatedFile('investor_statement', r.id, user.id);
    if (f) files.push({ name: `${r.return_month.slice(0, 7)}-${f.fileName.replace(/[^\w.-]+/g, '-')}`, data: f.bytes });
  }
  if (Number(year) < new Date().getUTCFullYear()) {
    const y = await generatedFile('investor_year', `${home.investor.id}:${year}`, user.id).catch(() => null);
    if (y) files.push({ name: `${year}-yearly-summary.pdf`, data: y.bytes });
  }
  files.push({ name: `${year}-returns.csv`, data: new TextEncoder().encode(csv) });
  return new Response(zip(files) as unknown as BodyInit, { headers: { ...headers, 'content-type': 'application/zip', 'content-disposition': `attachment; filename="CarmaCars-statements-${year}.zip"` } });
}
