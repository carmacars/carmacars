import { NextResponse, type NextRequest } from 'next/server';
import { assertAdmin } from '@/server/admin/data';
import { adminRead } from '@/server/admin/api';

// CSV exports of the statements (11-statements-and-reports.md section 4), Admin only.
export const dynamic = 'force-dynamic';
export async function GET(req: NextRequest) {
  let admin;
  try { admin = await assertAdmin(); } catch { return new NextResponse('Not permitted', { status: 403 }); }
  const q = req.nextUrl.searchParams;
  const kind = q.get('kind') ?? '';
  if (!['company', 'ledger', 'owner_statement'].includes(kind)) return new NextResponse('Unknown export', { status: 400 });
  const r = await adminRead<{ csv: string | null }>(admin.id, 'csv', { kind, month: q.get('month'), level: q.get('level') ?? 'vehicle', id: q.get('id') });
  const name = `carmacars-${kind}-${q.get('month') ?? q.get('id') ?? 'export'}${kind === 'company' ? `-${q.get('level') ?? 'vehicle'}` : ''}.csv`;
  return new NextResponse(r.csv ?? '', { headers: { 'content-type': 'text/csv; charset=utf-8', 'content-disposition': `attachment; filename="${name}"`, 'cache-control': 'no-store' } });
}
