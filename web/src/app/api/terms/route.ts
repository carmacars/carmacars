import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { pendingTerms } from '@/server/terms';
import { acceptTerms, declineTerms } from '@/server/actions/terms';
import { foreignOrigin } from '@/lib/security/same-origin';

// r48 FE (3198): the updated documents to accept, for the app (apps/carmacars) and any client with the session: GET lists
// what waits (title, version, "What changed", the full text's link); POST {version_id, action: accept | decline,
// body_sha256, portal} records it as the portal's pop-up does (the version, the time, the IP address, the device).
export const dynamic = 'force-dynamic';
const LINK: Record<string, string> = { terms: '/terms', privacy: '/privacy', rental_agreement: '/terms#rental-agreement', owner_agreement: '/owner/documents', staff_agreement: '/staff/documents' };

export async function GET() {
  const user = await currentUser();
  if (!user) return NextResponse.json({ ok: false, message: 'Sign in first.' }, { status: 401 });
  const rows = await pendingTerms(user.id).catch(() => []);
  return NextResponse.json({ ok: true, pending: rows.map((r) => ({ version_id: r.id, doc_key: r.doc_key, title: r.title, version: r.version, summary: r.summary,
    body_sha256: r.body_sha256, published_at: r.published_at, full_text: LINK[r.doc_key] ?? '/terms' })) });
}

export async function POST(req: Request) {
  if (foreignOrigin(req.headers.get('origin'), req.headers.get('host'), req.headers.get('sec-fetch-site'))) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  const b = (await req.json().catch(() => ({}))) as { version_id?: string; action?: string; body_sha256?: string; portal?: string };
  const r = b.action === 'decline' ? await declineTerms(String(b.version_id ?? ''), '') : await acceptTerms(String(b.version_id ?? ''), String(b.body_sha256 ?? ''), String(b.portal ?? 'renter'));
  return NextResponse.json(r, { status: r.ok ? 200 : 400 });
}
