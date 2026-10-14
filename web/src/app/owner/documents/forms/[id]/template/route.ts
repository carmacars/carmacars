import { rpc } from '@/lib/db/repo';
import { storage } from '@/integrations/storage';
import { currentUser } from '@/server/portal/data';
import { fileResponse } from '@/server/files';

// The blank official PDF of one of the owner's forms (migration 0042): the browser fills it with the values the
// database resolved, so nothing heavy runs here.
export const dynamic = 'force-dynamic';
export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const user = await currentUser();
  if (!user || !/^[0-9a-f-]{36}$/.test(id)) return new Response('Not found', { status: 404 });
  const f = (await rpc('owner_form_official', { p_by: user.id, p_fill: id }, { role: 'service_role' }).catch(() => null)) as unknown as { file_key: string; form_code: string } | null;
  if (!f?.file_key) return new Response('Not found', { status: 404 });
  const bytes = await (await storage()).get('documents', f.file_key);
  return bytes ? fileResponse({ bytes, fileName: `${f.form_code}.pdf`, contentType: 'application/pdf' }) : new Response('Not found', { status: 404 });
}
