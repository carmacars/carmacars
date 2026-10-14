import { currentUser } from '@/server/portal/data';
import { door, rolesOf, sessionAal } from '@/server/door';
import { storage } from '@/integrations/storage';
import { fileResponse } from '@/server/files';

// The scan of a witnessed owner form (Form C or D), for customer service reviewing it (migration 0040). The database
// decides: only a form's own document, only for customer service or an Admin.
export const dynamic = 'force-dynamic';

export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const nf = () => new Response('Not found', { status: 404, headers: { 'x-robots-tag': 'noindex' } });
  if (!/^[0-9a-f-]{36}$/.test(id)) return nf();
  const user = await currentUser();
  if (!user) return nf();
  const roles = await rolesOf(user.id);
  if (!roles.va && !roles.admin) return nf();
  const d = await door<{ bucket: string; path: string; mime_type: string | null } | null>(user.id, roles.admin ? 'admin_read' : 'va_read', 'form_document', { document: id }, await sessionAal()).catch(() => null);
  if (!d) return nf();
  const bytes = await (await storage()).get(d.bucket as 'documents', d.path);
  return bytes ? fileResponse({ bytes, fileName: d.path.split('/').pop() ?? 'form', contentType: d.mime_type ?? 'application/octet-stream' }) : nf();
}
