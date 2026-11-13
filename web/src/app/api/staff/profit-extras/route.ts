import { realUser } from '@/server/portal/data';
import { door } from '@/server/door';
import { storage } from '@/integrations/storage';
import { toCsv, type Extras } from '@/features/profit-extras/model';
import { foreignOrigin } from '@/lib/security/same-origin';

// Kickbacks and repair costs (release 29, C2; migration 0581), for Admin, Finance and Fleet (the database checks who):
// GET ?level=&id=&from=&to= the CSV of a view; GET ?receipt=<repair cost> its receipt; POST (vehicle, file) a receipt
// into private storage before the repair cost is saved.
export const dynamic = 'force-dynamic';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const MAX = 10 * 1024 * 1024;
const H = { 'cache-control': 'no-store' };

export async function GET(req: Request) {
  const user = await realUser();
  if (!user) return new Response('Not found', { status: 404 });
  const u = new URL(req.url);
  try {
    const receipt = u.searchParams.get('receipt');
    if (receipt !== null) {
      if (!UUID.test(receipt)) return new Response('Not found', { status: 404 });
      const r = await door<{ path: string } | null>(user.id, 'ops_read', 'repair_receipt', { id: receipt });
      const bytes = r?.path ? await (await storage()).get('documents', r.path) : null;
      if (!bytes) return new Response('Not found', { status: 404 });
      const type = r!.path.endsWith('.pdf') ? 'application/pdf' : r!.path.endsWith('.png') ? 'image/png' : 'image/jpeg';
      return new Response(bytes as unknown as BodyInit, { headers: { 'content-type': type, 'cache-control': 'private, max-age=300' } });
    }
    const level = u.searchParams.get('level') ?? 'business';
    const id = u.searchParams.get('id');
    const from = u.searchParams.get('from'), to = u.searchParams.get('to');
    if (!['business', 'owner', 'vehicle'].includes(level) || (id && !UUID.test(id))) return new Response('Not found', { status: 404 });
    const x = await door<Extras>(user.id, 'ops_read', 'profit_extras', { level, id: id || null, from: from && DAY.test(from) ? from : null, to: to && DAY.test(to) ? to : null });
    return new Response(toCsv(x), { headers: { ...H, 'content-type': 'text/csv; charset=utf-8', 'content-disposition': `attachment; filename="kickbacks-repairs-${level}-${x.from}-${x.to}.csv"` } });
  } catch { return new Response('Not found', { status: 404 }); }
}

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (foreignOrigin(origin, req.headers.get('host'))) return Response.json({ ok: false, message: 'Not permitted.' }, { status: 403, headers: H });
  const user = await realUser();
  if (!user) return Response.json({ ok: false, message: 'Sign in first.' }, { status: 401, headers: H });
  // the people who may record repair costs (the cost itself is checked again when it is saved)
  try { await door(user.id, 'ops_read', 'profit_cars', {}); } catch { return Response.json({ ok: false, message: 'Not permitted.' }, { status: 403, headers: H }); }
  const form = await req.formData().catch(() => null);
  const vehicle = String(form?.get('vehicle') ?? '');
  const folder = UUID.test(vehicle) ? vehicle.toLowerCase() : crypto.randomUUID();
  const file = form?.get('file');
  if (!(file instanceof Blob) || file.size === 0 || file.size > MAX) return Response.json({ ok: false, message: 'The receipt must be under 10 MB.' }, { status: 400, headers: H });
  const b = new Uint8Array(await file.arrayBuffer());
  const kind = b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff ? 'jpg' : b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 ? 'png' : b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46 ? 'pdf' : null;
  if (!kind) return Response.json({ ok: false, message: 'The receipt must be a photo or a PDF.' }, { status: 400, headers: H });
  const key = `repair-receipts/${folder}/${crypto.randomUUID()}.${kind}`;
  await (await storage()).put('documents', key, b, kind === 'pdf' ? 'application/pdf' : kind === 'png' ? 'image/png' : 'image/jpeg');
  return Response.json({ ok: true, path: key }, { headers: H });
}
