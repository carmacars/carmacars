import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { storage } from '@/integrations/storage';
import { currentUser } from '@/server/portal/data';
import { sha256Hex } from '@/server/links';

// The owner's official form, filled and signed on screen in the browser (migration 0042): stored in the private
// agreements bucket under the owner, filed as a registry form, and the form is marked signed.
export const dynamic = 'force-dynamic';
const MAX = 15 * 1024 * 1024;
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  const { id } = await params;
  const user = await currentUser();
  if (!user) return NextResponse.json({ ok: false, message: 'Sign in first.' }, { status: 401 });
  if (!/^[0-9a-f-]{36}$/.test(id)) return NextResponse.json({ ok: false, message: 'Unknown form.' }, { status: 404 });
  const f = (await rpc('owner_form_official', { p_by: user.id, p_fill: id }, { role: 'service_role' }).catch(() => null)) as unknown as { form_code: string; vehicle_id: string; owner_id: string } | null;
  if (!f) return NextResponse.json({ ok: false, message: 'That form is not yours to sign.' }, { status: 403 });
  const bytes = new Uint8Array(await req.arrayBuffer());
  if (!bytes.length || bytes.length > MAX || !(bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46)) return NextResponse.json({ ok: false, message: 'Send the signed form as a PDF under 15 MB.' }, { status: 400 });
  const key = `owners/${f.owner_id}/vehicles/${f.vehicle_id}/forms/${f.form_code}-signed-${crypto.randomUUID().slice(0, 8)}.pdf`;
  const s = await storage();
  await s.put('agreements', key, bytes, 'application/pdf');
  try {
    const r = await rpc('owner_form_signed', { p_by: user.id, p_fill: id, p: { storage_path: key, sha256: await sha256Hex(bytes) } }, { role: 'service_role' });
    return NextResponse.json({ ok: true, ...(r as unknown as Record<string, unknown>) });
  } catch (e) {
    await s.remove('agreements', key).catch(() => undefined);
    return NextResponse.json({ ok: false, message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'The form could not be saved.' }, { status: 422 });
  }
}
