import { assertAdmin } from '@/server/admin/data';
import { door } from '@/server/door';
import { storage } from '@/integrations/storage';
import { fileResponse } from '@/server/files';

// The blank official PDF of a template, for the Admin's mapping preview.
export const dynamic = 'force-dynamic';
export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) return new Response('Not found', { status: 404 });
  let admin;
  try { admin = await assertAdmin(); } catch { return new Response('Not found', { status: 404 }); }
  const t = await door<{ file_key: string } | null>(admin.id, 'ops_read', 'form_template_preview', { template: id }).catch(() => null);
  if (!t?.file_key) return new Response('Not found', { status: 404 });
  const bytes = await (await storage()).get('documents', t.file_key);
  return bytes ? fileResponse({ bytes, fileName: t.file_key.split('/').pop() ?? 'form.pdf', contentType: 'application/pdf' }) : new Response('Not found', { status: 404 });
}
