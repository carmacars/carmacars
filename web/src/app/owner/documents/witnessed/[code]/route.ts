import { rpc } from '@/lib/db/repo';
import { storage } from '@/integrations/storage';
import { agreementPdf } from '@/features/agreement/pdf';
import { FORM_TITLE, WITNESSED_FORMS_VERSION, witnessedBlocks, type WitnessedFacts } from '@/features/owner-agreement/witnessed';
import { currentUser } from '@/server/portal/data';
import { fileResponse } from '@/server/files';

// The pre-filled Form C (one financed or leased car) or Form D, as a PDF to print, sign with witnesses and upload
// (migration 0040). The database checks the form is one this owner needs.
export const dynamic = 'force-dynamic';

export async function GET(req: Request, { params }: { params: Promise<{ code: string }> }) {
  const { code } = await params;
  const vehicle = new URL(req.url).searchParams.get('vehicle');
  const nf = () => new Response('Not found', { status: 404, headers: { 'x-robots-tag': 'noindex' } });
  if (!['C', 'D'].includes(code) || (vehicle && !/^[0-9a-f-]{36}$/.test(vehicle))) return nf();
  const user = await currentUser();
  if (!user) return Response.redirect(new URL(`/sign-in?next=${encodeURIComponent('/owner/documents')}`, req.url), 303);
  const f = (await rpc('server_witnessed_form_facts', { p_by: user.id, p_code: code === 'C' ? 'C' : 'D1', p_vehicle: vehicle ?? undefined }, { role: 'service_role' }).catch(() => null)) as unknown as WitnessedFacts | null;
  if (!f) return nf();
  const k = f.company.logo_key;
  const logo = k && /\.(png|jpe?g)$/i.test(k) ? await (await storage()).get('vehicle-public', k).catch(() => null) : null;
  const pdf = await agreementPdf(witnessedBlocks(f), { title: FORM_TITLE[f.code], createdAt: new Date(), brand: true, logo,
    footer: `${f.company.brand}. ${FORM_TITLE[f.code]} for ${f.owner.legal_name}. ${WITNESSED_FORMS_VERSION}` });
  return fileResponse({ bytes: pdf, fileName: `carmacars-form-${code.toLowerCase()}${vehicle ? `-${vehicle.slice(0, 8)}` : ''}.pdf`, contentType: 'application/pdf' });
}
