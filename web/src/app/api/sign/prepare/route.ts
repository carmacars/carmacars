import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { ownerHome } from '@/server/owner/data';
import { parseTarget, prepareSpec, specFor, targetId } from '@/server/signing/prepare';
import { viewAs } from '@/server/view-as';

// Prepares one document for signature (migration 0077): the sign page shows the text at once and asks here, one
// request per document, for the PDF to be rendered, stored and opened (src/server/signing/prepare.ts). The document is
// built from the signed-in owner's own records; the browser only names which one. Idempotent: an open document with
// the same content answers at once.
export const dynamic = 'force-dynamic';
const reply = (o: unknown, status = 200) => NextResponse.json(o, { status, headers: { 'cache-control': 'no-store' } });

export async function POST(req: Request) {
  const user = await currentUser();
  if (!user) return reply({ ok: false, message: 'Sign in again to continue.' }, 401);
  if (await viewAs()) return reply({ ok: false, message: 'Read only while viewing as someone.' }, 403);
  const target = parseTarget(await req.json().catch(() => null));
  if (!target) return reply({ ok: false, message: 'Unknown document.' }, 400);
  const t0 = Date.now();
  try {
    const home = await ownerHome(user);
    if (!home) return reply({ ok: false, message: 'This account is not an owner account.' }, 403);
    const spec = await specFor(user.id, home.owner?.id ?? '', target);
    if (!spec) return reply({ ok: true, gone: true, id: targetId(target) });
    const open = await prepareSpec(user.id, spec);
    return reply({ ok: true, id: targetId(target), sha: open.sha, ms: Date.now() - t0 });
  } catch (e) {
    console.error('sign prepare', targetId(target), e);
    return reply({ ok: false, message: 'We could not prepare this document. Try again in a moment.' }, 500);
  }
}
