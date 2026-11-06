import { realUser } from '@/server/portal/data';
import { door } from '@/server/door';
import { storage } from '@/integrations/storage';
import { fileResponse } from '@/server/files';
import { renderPartnerInvoice } from '@/features/documents/pdf';
import { MAX_PHOTO_BYTES, UUID } from '@/features/returns/claim';

// 0547: Finance and Admins: ?id=<invoice> the PDF (drafts too); ?id=<invoice>&photo=<key> a cheque photo; ?csv=1 every
// invoice for the bookkeeper. POST (id, file): a cheque photo for a payment about to be recorded, private storage.
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
    const photo = u.searchParams.get('photo');
    if (photo !== null) {
      const known = ((f.payments ?? []) as Array<{ photo_path?: string | null }>).some((x) => x.photo_path === photo);
      const bytes = known ? await (await storage()).get('documents', photo) : null;
      if (!bytes) return new Response('Not found', { status: 404 });
      return new Response(bytes as unknown as BodyInit, { headers: { 'content-type': photo.endsWith('.png') ? 'image/png' : 'image/jpeg', 'cache-control': 'private, max-age=300' } });
    }
    const key = (f.company as { logo_key?: string | null } | undefined)?.logo_key ?? null;
    const logo = key && /\.(png|jpe?g)$/i.test(key) ? await (await storage()).get('vehicle-public', key).catch(() => null) : null;
    return fileResponse({ bytes: await renderPartnerInvoice(f, logo), fileName: `${String(f.invoice_number ?? 'draft-invoice')}.pdf`, contentType: 'application/pdf' });
  } catch { return new Response('Not found', { status: 404 }); }
}

const H = { 'cache-control': 'no-store' };
export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return Response.json({ ok: false, message: 'Not permitted.' }, { status: 403, headers: H });
  const user = await realUser();
  if (!user) return Response.json({ ok: false, message: 'Sign in first.' }, { status: 401, headers: H });
  const form = await req.formData().catch(() => null);
  const id = String(form?.get('id') ?? '');
  if (!UUID.test(id)) return Response.json({ ok: false, message: 'Not permitted.' }, { status: 400, headers: H });
  // the same check as the invoice itself: Finance or an Admin (the payment is checked again when it is recorded)
  try { await door(user.id, 'ops_read', 'partner_invoices', { id }); } catch { return Response.json({ ok: false, message: 'Not permitted.' }, { status: 403, headers: H }); }
  const file = form?.get('file');
  if (!(file instanceof Blob) || file.size === 0 || file.size > MAX_PHOTO_BYTES) return Response.json({ ok: false, message: 'The photo must be under 8 MB.' }, { status: 400, headers: H });
  const bytes = new Uint8Array(await file.arrayBuffer());
  const jpg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  const png = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
  if (!jpg && !png) return Response.json({ ok: false, message: 'That file is not a photo.' }, { status: 400, headers: H });
  const key = `partner-invoices/${id.toLowerCase()}/${crypto.randomUUID()}.${png ? 'png' : 'jpg'}`;
  await (await storage()).put('documents', key, bytes, png ? 'image/png' : 'image/jpeg');
  return Response.json({ ok: true, path: key }, { headers: H });
}
