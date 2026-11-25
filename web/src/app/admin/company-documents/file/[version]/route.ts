import { door, sessionAal } from '@/server/door';
import { storage, type Bucket } from '@/integrations/storage';
import { currentUser } from '@/server/portal/data';
import { downloadName } from '@/features/investor/library';

// One version of a company document, for Admins (r50, migration 5060): a PDF, or the signed copy of a text everyone signed,
// opened through a 5-minute signed link. The database checks the Admin (admin_read company_document_file).
export const dynamic = 'force-dynamic';

export async function GET(req: Request, { params }: { params: Promise<{ version: string }> }) {
  const version = (await params).version;
  const user = await currentUser();
  if (!user) return Response.redirect(new URL(`/sign-in?next=${encodeURIComponent('/admin/company-documents')}`, req.url), 302);
  if (!/^[0-9a-f-]{36}$/.test(version)) return new Response('Not found', { status: 404 });
  const f = await door<{ bucket: string; path: string; title: string; version: number; signed: boolean }>(user.id, 'admin_read', 'company_document_file', { version }, await sessionAal()).catch(() => null);
  if (!f?.bucket || !f.path) return new Response('Not found', { status: 404 });
  const name = downloadName(f.signed ? `${f.title} signed` : f.title, f.version);
  const url = await (await storage()).signedDownloadUrl(f.bucket as Bucket, f.path, 300, name);
  return new Response(null, { status: 302, headers: { 'cache-control': 'no-store', 'referrer-policy': 'no-referrer', location: new URL(url, req.url).toString() } });
}
