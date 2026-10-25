import { flyerPdf } from '@/features/referral/flyer';
import { partnerLink } from '@/server/referral/portal';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';

// The one-page flyer with the partner's QR code, for their counter (migration 0164). An Admin only; made from the partner's record.
export const dynamic = 'force-dynamic';

export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const id = (await params).id;
  const user = await currentUser();
  if (!user) return Response.redirect(new URL(`/sign-in?next=${encodeURIComponent(`/admin/referral-partners/${id}`)}`, req.url), 302);
  let d: { partner: { business_name: string; kind: string; referral_code: string; status: string } } | null = null;
  try { d = await door(user.id, 'admin_read', 'referral_partner', { id }, await sessionAal()); } catch { return new Response('Not found', { status: 404 }); }
  if (!d?.partner) return new Response('Not found', { status: 404 });
  const site = await door<{ site?: { phone_display?: string | null } }>(user.id, 'admin_read', 'settings', {}, await sessionAal()).catch(() => null);
  const pdf = await flyerPdf({ business: d.partner.business_name, code: d.partner.referral_code, link: partnerLink(d.partner.referral_code), kind: d.partner.kind, phone: site?.site?.phone_display ?? '' });
  return new Response(pdf as unknown as BodyInit, { headers: { 'content-type': 'application/pdf', 'content-disposition': `inline; filename="carmacars-flyer-${d.partner.referral_code}.pdf"`, 'cache-control': 'no-store' } });
}
