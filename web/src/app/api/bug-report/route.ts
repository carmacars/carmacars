import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { storage } from '@/integrations/storage';
import { SCHEMA_MARKER } from '@/lib/schema-marker';
import { MAX_SHOTS, MAX_SHOT_BYTES, MIN_HAPPENED, SEVERITIES, cleanContext, cleanLogs, imageKind, pagePath, redact } from '@/features/bug-report/logs';
import { foreignOrigin } from '@/lib/security/same-origin';

// Release 37 (2340): a bug report from a staff member or an Admin. POST (form: report = JSON of the fields, the browser's
// context and its last errors; shot = up to six images, the page's own picture first): the images go to the private
// documents bucket under bug-reports/<id>/, then the database keeps the report (and alerts the Admins: at once when it
// blocks work, else in the morning digest). Everything from the browser is cleaned again here. GET ?id=<report>&n=<i>:
// one screenshot, for its reporter or an Admin (the database decides). Never cached; never posted anywhere else.
export const dynamic = 'force-dynamic';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const H = { 'cache-control': 'private, no-store' };
type Shot = { path: string; mime: string; bytes: number; kind: string };
const msg = (e: unknown, d: string) => (e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : d);

async function build(): Promise<string | null> {
  try { return await (await import('@/lib/platform/runtime')).deploymentId(); } catch { return null; }
}

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  const host = req.headers.get('host');
  if (foreignOrigin(origin, host, req.headers.get('sec-fetch-site'))) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403, headers: H });
  const user = await currentUser();
  if (!user) return NextResponse.json({ ok: false, message: 'Sign in first.' }, { status: 401, headers: H });
  const form = await req.formData().catch(() => null);
  let r: Record<string, unknown>;
  try { r = JSON.parse(String(form?.get('report') ?? '')) as Record<string, unknown>; } catch { return NextResponse.json({ ok: false, message: 'The report is missing.' }, { status: 400, headers: H }); }
  const happened = typeof r.happened === 'string' ? r.happened.trim() : '';
  if (happened.length < MIN_HAPPENED) return NextResponse.json({ ok: false, message: `Describe what happened in at least ${MIN_HAPPENED} characters.` }, { status: 400, headers: H });
  if (!SEVERITIES.some(([k]) => k === r.severity)) return NextResponse.json({ ok: false, message: 'Choose how bad it is.' }, { status: 400, headers: H });
  const files = (form?.getAll('shot') ?? []).filter((f): f is File => f instanceof File && f.size > 0);
  if (files.length > MAX_SHOTS) return NextResponse.json({ ok: false, message: `At most ${MAX_SHOTS} pictures.` }, { status: 400, headers: H });
  if (files.some((f) => f.size > MAX_SHOT_BYTES)) return NextResponse.json({ ok: false, message: 'Each picture must be under 5 MB.' }, { status: 413, headers: H });

  const id = crypto.randomUUID();
  const site = `https://${host ?? 'carmacars.ca'}`;
  const st = await storage();
  const shots: Shot[] = [];
  try {
    for (const [i, f] of files.entries()) {
      const bytes = new Uint8Array(await f.arrayBuffer());
      const kind = imageKind(bytes);
      if (!kind) throw new Error('Pictures must be PNG, JPEG or WebP images.');
      const path = `bug-reports/${id}/${crypto.randomUUID()}.${kind.ext}`;
      await st.put('documents', path, bytes, kind.mime);
      shots.push({ path, mime: kind.mime, bytes: bytes.length, kind: i === 0 && r.auto_shot === true ? 'auto' : 'upload' });
    }
    const context = { ...cleanContext(r.context), schema: SCHEMA_MARKER, build: (await build()) ?? SCHEMA_MARKER, user_agent: redact(req.headers.get('user-agent') ?? '', 300),
      reported_at: new Date().toISOString(), user_id: user.id };
    const data = await door<Record<string, unknown>>(user.id, 'ops_do', 'bug_report_create', {
      id, happened: happened.slice(0, 4000), expected: typeof r.expected === 'string' ? r.expected.slice(0, 2000) : null, steps: typeof r.steps === 'string' ? r.steps.slice(0, 4000) : null,
      severity: r.severity, portal: ['admin', 'staff', 'field'].includes(String(r.portal)) ? r.portal : 'staff', page_path: pagePath(String(r.page ?? '/'), site),
      context, client_logs: cleanLogs(r.logs, site), screenshots: shots
    }, await sessionAal());
    return NextResponse.json({ ok: true, data }, { headers: H });
  } catch (e) {
    await Promise.all(shots.map((s) => st.remove('documents', s.path).catch(() => undefined)));
    return NextResponse.json({ ok: false, message: msg(e, 'The report was not sent.') }, { status: 400, headers: H });
  }
}

export async function GET(req: Request) {
  const q = new URL(req.url).searchParams;
  const id = q.get('id') ?? '';
  const n = Number(q.get('n') ?? 0);
  if (!UUID.test(id) || !Number.isInteger(n) || n < 0 || n > 5) return new NextResponse('Unknown picture.', { status: 400 });
  const user = await currentUser();
  if (!user) return new NextResponse('Sign in first.', { status: 401 });
  let shots: Shot[];
  try { shots = ((await door<{ screenshots?: Shot[] }>(user.id, 'ops_read', 'bug_reports', { id }, await sessionAal())).screenshots ?? []); }
  catch { return new NextResponse('Not permitted.', { status: 403 }); }
  const s = shots[n];
  if (!s || !s.path.startsWith(`bug-reports/${id}/`)) return new NextResponse('No such picture.', { status: 404 });
  const body = await (await storage()).get('documents', s.path).catch(() => null);
  if (!body) return new NextResponse('The picture could not be read.', { status: 404 });
  return new NextResponse(body as unknown as BodyInit, { headers: { 'content-type': s.mime, ...H, 'x-content-type-options': 'nosniff', 'content-disposition': `inline; filename="bug-${id.slice(0, 8)}-${n + 1}.${s.path.split('.').pop()}"` } });
}
