import { rpc } from '@/lib/db/repo';
import { storage } from '@/integrations/storage';
import { fileResponse } from '@/server/files';
import { renderPartnerInvoice } from '@/features/documents/pdf';
import { UUID } from '@/features/returns/claim';

// 0547: an invoice to a partner, by the private link in its email and on the partner's page: the PDF, rendered now
// (what it shows follows the payments recorded). A void or draft invoice answers 404.
export const dynamic = 'force-dynamic';
export async function GET(_req: Request, { params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  if (!UUID.test(token)) return new Response('Not found', { status: 404 });
  const f = (await rpc('server_partner_invoice_by_token' as never, { p_token: token } as never, { role: 'service_role', skipViewAs: true }).catch(() => null)) as unknown as Record<string, unknown> | null;
  if (!f) return new Response('Not found', { status: 404 });
  const key = (f.company as { logo_key?: string | null } | undefined)?.logo_key ?? null;
  const logo = key && /\.(png|jpe?g)$/i.test(key) ? await (await storage()).get('vehicle-public', key).catch(() => null) : null;
  const bytes = await renderPartnerInvoice(f, logo);
  return fileResponse({ bytes, fileName: `${String(f.invoice_number ?? 'invoice')}.pdf`, contentType: 'application/pdf' });
}
