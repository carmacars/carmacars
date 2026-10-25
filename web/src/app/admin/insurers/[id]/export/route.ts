import { NextResponse, type NextRequest } from 'next/server';
import { assertAdmin } from '@/server/admin/data';
import { adminRead } from '@/server/admin/api';
import { billingCsv, billingFileName, type BillingRow } from '@/features/insurers/rates';

// An insurer's billing history as CSV (migration 0163), Admin only: one line per booking for the period asked.
export const dynamic = 'force-dynamic';
const DATE = /^\d{4}-\d{2}-\d{2}$/;
export async function GET(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  let admin;
  try { admin = await assertAdmin(); } catch { return new NextResponse('Not permitted', { status: 403 }); }
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) return new NextResponse('Unknown insurer', { status: 404 });
  const q = req.nextUrl.searchParams;
  const from = DATE.test(q.get('from') ?? '') ? q.get('from') : null;
  const to = DATE.test(q.get('to') ?? '') ? q.get('to') : null;
  const x = await adminRead<{ insurer: { name: string }; today: string; bookings: BillingRow[] } | null>(admin.id, 'insurer_billing', { insurer: id, from, to });
  if (!x) return new NextResponse('Unknown insurer', { status: 404 });
  return new NextResponse(billingCsv(x.insurer.name, x.bookings), {
    headers: { 'content-type': 'text/csv; charset=utf-8', 'content-disposition': `attachment; filename="${billingFileName(x.insurer.name, x.today)}"`, 'cache-control': 'no-store' }
  });
}
