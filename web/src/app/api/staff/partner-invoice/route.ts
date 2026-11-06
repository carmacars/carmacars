import { realUser } from '@/server/portal/data';
import { door } from '@/server/door';
import { storage } from '@/integrations/storage';
import { fileResponse } from '@/server/files';
import { renderPartnerInvoice } from '@/features/documents/pdf';
import { UUID } from '@/features/returns/claim';

// 0547: Finance and Admins: ?id=<invoice> the PDF (drafts too); ?csv=1 every invoice for the bookkeeper.
export const dynamic = 'force-dynamic';
const cents = (c: unknown) => (Number(c ?? 0) / 100).toFixed(2);
const cell = (v: unknown) => { const t = String(v ?? ''); return /[",\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t; };
export async function GET(req: Request) {
  const user = await realUser();
  if (!user) return new Response('Not found', { status: 404 });
  const u = new URL(req.url);
  try {
    if (u.searchParams.get('csv') === '1') {
      const d = await door<{ invoices: Array<Record<string, unknown>> }>(user.id, 'ops_read', 'partner_invoices', {});
      const rows = [['Invoice', 'Partner', 'Claim', 'Kind', 'Issued', 'Due', 'Status', 'Total', 'Received', 'Outstanding'],
        ...d.invoices.map((i) => [i.invoice_number ?? 'draft', i.partner, i.claim_number, i.kind, i.issued_on, i.due_on, i.state, cents(i.total_cents), cents(i.paid_cents), cents(i.balance_cents)])];
      return new Response(rows.map((r) => r.map(cell).join(',')).join('\r\n') + '\r\n', { headers: { 'content-type': 'text/csv; charset=utf-8', 'content-disposition': 'attachment; filename="partner-invoices.csv"', 'cache-control': 'no-store' } });
    }
    const id = u.searchParams.get('id') ?? '';
    if (!UUID.test(id)) return new Response('Not found', { status: 404 });
    const f = await door<Record<string, unknown>>(user.id, 'ops_read', 'partner_invoices', { id });
    const key = (f.company as { logo_key?: string | null } | undefined)?.logo_key ?? null;
    const logo = key && /\.(png|jpe?g)$/i.test(key) ? await (await storage()).get('vehicle-public', key).catch(() => null) : null;
    return fileResponse({ bytes: await renderPartnerInvoice(f, logo), fileName: `${String(f.invoice_number ?? 'draft-invoice')}.pdf`, contentType: 'application/pdf' });
  } catch { return new Response('Not found', { status: 404 }); }
}
