import { NextResponse, type NextRequest } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { ledgerCsv, ledgerFilters, torontoToday, type Ledger } from '@/features/money/ledger';

// The Payments view as CSV (0151): an Admin or Finance, the same filters as the page. The database checks again.
export const dynamic = 'force-dynamic';
export async function GET(req: NextRequest) {
  const user = await currentUser();
  if (!user) return new NextResponse('Sign in first', { status: 401 });
  const roles = await rolesOf(user.id);
  if (!roles.admin && roles.va !== 'finance') return new NextResponse('Not permitted', { status: 403 });
  const aal = await sessionAal();
  if (roles.two_step_required && aal !== 'aal2') return new NextResponse('Two-step sign-in is required', { status: 403 });
  const sp = Object.fromEntries([...new Set(req.nextUrl.searchParams.keys())].map((k) => [k, req.nextUrl.searchParams.getAll(k)]));
  const f = ledgerFilters({ ...sp, from: sp.from?.[0], to: sp.to?.[0] }, torontoToday());
  try {
    const l = await door<Ledger>(user.id, 'ops_read', 'payments_ledger', { ...f, ...(roles.admin ? {} : { _va: 'finance' }) }, aal);
    const name = `carmacars-payments-${f.from}${f.to !== f.from ? `-to-${f.to}` : ''}.csv`;
    return new NextResponse(ledgerCsv(l.rows), { headers: { 'content-type': 'text/csv; charset=utf-8', 'content-disposition': `attachment; filename="${name}"`, 'cache-control': 'no-store' } });
  } catch (e) {
    return new NextResponse(e instanceof Error ? e.message : 'Not permitted', { status: 403 });
  }
}
