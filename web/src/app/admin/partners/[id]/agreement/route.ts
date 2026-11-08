import { agreementPdf } from '@/features/agreement/pdf';
import { partnerAgreementBlocks, PARTNER_AGREEMENT_TITLE, PARTNER_AGREEMENT_VERSION, type PartnerFacts } from '@/features/partner/agreement';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';

// The partner agreement to read (Admins, migration 0046): filled from the partner record, the same text the partner
// signs in the portal. Since 0720 it is signed in the portal only (no paper copy is recorded).
export const dynamic = 'force-dynamic';

export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const id = (await params).id;
  const user = await currentUser();
  if (!user) return Response.redirect(new URL(`/sign-in?next=${encodeURIComponent(`/admin/partners/${id}`)}`, req.url), 302);
  let facts: PartnerFacts | null = null;
  try { facts = await door<PartnerFacts | null>(user.id, 'ops_read', 'partner_agreement_facts', { partner_id: id }, await sessionAal()); } catch { return new Response('Not found', { status: 404 }); }
  if (!facts) return new Response('Not found', { status: 404 });
  const name = facts.partner.legal_name || facts.partner.business_name;
  const pdf = await agreementPdf(partnerAgreementBlocks(facts), { title: `${PARTNER_AGREEMENT_TITLE}, ${name}`, createdAt: new Date(), footer: `CarmaCars ${PARTNER_AGREEMENT_TITLE} for ${name}. ${PARTNER_AGREEMENT_VERSION}` });
  return new Response(pdf as unknown as BodyInit, { headers: { 'content-type': 'application/pdf', 'content-disposition': `inline; filename="partner-agreement-${facts.partner_number}.pdf"`, 'cache-control': 'no-store' } });
}
