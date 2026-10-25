import { NextResponse, type NextRequest } from 'next/server';
import { assertAdmin } from '@/server/admin/data';
import { door } from '@/server/door';
import { payRunCsv, type PayCsvRow } from '@/features/field-pay/model';

// The pay run as a CSV for the accountant (0165), Admin only; the database checks the Admin again.
export const dynamic = 'force-dynamic';
export async function GET(req: NextRequest) {
  let admin;
  try { admin = await assertAdmin(); } catch { return new NextResponse('Not permitted', { status: 403 }); }
  const run = req.nextUrl.searchParams.get('run') ?? '';
  if (!/^[0-9a-f-]{36}$/.test(run)) return new NextResponse('Unknown pay run', { status: 400 });
  try {
    const r = await door<{ period_start: string; period_end: string; rows: PayCsvRow[] }>(admin.id, 'ops_read', 'field_pay_csv', { run_id: run });
    const csv = payRunCsv({ start: r.period_start, end: r.period_end }, r.rows);
    return new NextResponse(csv, { headers: { 'content-type': 'text/csv; charset=utf-8', 'content-disposition': `attachment; filename="carmacars-field-pay-${r.period_start}.csv"`, 'cache-control': 'no-store' } });
  } catch { return new NextResponse('Not found', { status: 404 }); }
}
