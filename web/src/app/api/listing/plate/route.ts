import { NextResponse } from 'next/server';
import { revalidatePath } from 'next/cache';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { storage } from '@/integrations/storage';

// A listing photo with its plate covered (migration 0042). The browser drew the cover, pixelation or blur on a
// canvas and sends the new file (and its smaller sizes when the photo had them). Here: the person's right to edit
// listing photos is checked by the database; the new files go to the public bucket under new names; the public
// file as it was is copied to the private vehicle-originals bucket (kept, never shown) the first time; the photo
// row points to the covered file; the old public files are removed; the car's pages are rebuilt.
export const dynamic = 'force-dynamic';
const MAX = 15 * 1024 * 1024;
type Ctx = { id: string; vehicle_id: string; processed_path: string | null; variants: Array<{ width: number; format: string; path: string }> | null; uncovered_path: string | null; replaced: boolean };
const jpeg = (b: Uint8Array) => b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
const ext = (p: string) => (/\.(\w+)$/.exec(p)?.[1] ?? 'jpg').toLowerCase();
const type = (p: string) => ({ png: 'image/png', webp: 'image/webp', avif: 'image/avif' } as Record<string, string>)[ext(p)] ?? 'image/jpeg';

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  const user = await currentUser();
  if (!user) return NextResponse.json({ ok: false, message: 'Sign in first.' }, { status: 401 });
  const aal = await sessionAal();
  const form = await req.formData().catch(() => null);
  const photo = String(form?.get('photo') ?? '');
  if (!/^[0-9a-f-]{36}$/.test(photo)) return NextResponse.json({ ok: false, message: 'Unknown photo.' }, { status: 400 });
  let ctx: Ctx;
  try { ctx = await door<Ctx>(user.id, 'ops_read', 'photo_plate_context', { photo }, aal); }
  catch (e) { return NextResponse.json({ ok: false, message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Not permitted.' }, { status: 403 }); }
  if (!ctx || ctx.replaced || !ctx.processed_path) return NextResponse.json({ ok: false, message: 'This photo is not ready to edit.' }, { status: 409 });
  let boxes: unknown;
  try { boxes = JSON.parse(String(form?.get('boxes') ?? '[]')); } catch { return NextResponse.json({ ok: false, message: 'The boxes could not be read.' }, { status: 400 }); }
  const main = form?.get('file');
  if (!(main instanceof Blob) || main.size === 0 || main.size > MAX) return NextResponse.json({ ok: false, message: 'The covered photo must be under 15 MB.' }, { status: 400 });
  const bytes = new Uint8Array(await main.arrayBuffer());
  if (!jpeg(bytes)) return NextResponse.json({ ok: false, message: 'The covered photo must be a JPEG.' }, { status: 400 });
  const variants: Array<{ width: number; bytes: Uint8Array }> = [];
  for (const [k, v] of form!.entries()) {
    const w = /^variant:(\d{2,4})$/.exec(k)?.[1];
    if (!w || !(v instanceof Blob) || v.size === 0 || v.size > MAX || variants.length >= 6) continue;
    const b = new Uint8Array(await v.arrayBuffer());
    if (jpeg(b)) variants.push({ width: Number(w), bytes: b });
  }

  const s = await storage();
  const tag = crypto.randomUUID().slice(0, 6);
  // always under the car's own folder, whatever the first file's name was
  const name = (ctx.processed_path.split('/').pop() ?? 'photo').replace(/\.\w+$/, '').replace(/-c[0-9a-f]{6}(-\d+)?$/, '').replace(/[^\w-]+/g, '-').slice(0, 80) || 'photo';
  const base = `vehicles/${ctx.vehicle_id}/${name}`;
  const path = `${base}-c${tag}.jpg`;
  const written = [path];
  await s.put('vehicle-public', path, bytes, 'image/jpeg');
  const outVariants: Array<{ width: number; format: string; path: string }> = [];
  for (const v of variants) {
    const vp = `${base}-c${tag}-${v.width}.jpg`;
    await s.put('vehicle-public', vp, v.bytes, 'image/jpeg');
    written.push(vp); outVariants.push({ width: v.width, format: 'jpg', path: vp });
  }
  // the public file as it was, kept privately the first time a plate is covered
  let uncovered = ctx.uncovered_path;
  if (!uncovered) {
    const old = await s.get('vehicle-public', ctx.processed_path).catch(() => null);
    if (old) {
      uncovered = `vehicles/${ctx.vehicle_id}/uncovered/${ctx.id}-${tag}.${ext(ctx.processed_path)}`;
      await s.put('vehicle-originals', uncovered, old, type(ctx.processed_path));
    }
  }
  const dims = (k: string) => { const n = Number(form?.get(k)); return Number.isInteger(n) && n > 0 && n < 20000 ? n : null; };
  let res: { previous_path: string | null; previous_variants: Array<{ path: string }> | null };
  try {
    res = await door(user.id, 'ops_do', 'photo_plate_record', { photo, status: 'covered', style: String(form?.get('style') ?? ''), boxes,
      processed_path: path, variants: outVariants, uncovered_path: uncovered, width: dims('width'), height: dims('height'), byte_size: bytes.length }, aal);
  } catch (e) {
    for (const p of written) await s.remove('vehicle-public', p).catch(() => undefined);
    return NextResponse.json({ ok: false, message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'The photo could not be saved.' }, { status: 422 });
  }
  // the old public files (the uncovered one, or an earlier cover) are taken off the public bucket
  for (const p of [res.previous_path, ...(res.previous_variants ?? []).map((v) => v.path)]) {
    if (p && !written.includes(p)) await s.remove('vehicle-public', p).catch(() => undefined);
  }
  revalidatePath('/cars/[slug]', 'page'); revalidatePath('/cars'); revalidatePath('/rent/[hub]', 'page'); revalidatePath('/', 'layout');
  return NextResponse.json({ ok: true, path, variants: outVariants });
}
