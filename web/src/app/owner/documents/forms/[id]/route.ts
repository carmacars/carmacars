import { agreementPdf } from '@/features/agreement/pdf';
import type { Block } from '@/features/agreement/model';
import { currentUser } from '@/server/portal/data';
import { ownerForms } from '@/server/owner/data';

// A government form's data sheet as a PDF (08-forms.md section 9.3): every value the owner copies onto
// the registry form, in the form's order, from public.owner_portal_forms. Used until a template is
// verified; a verified template's pre-filled PDF replaces it.
export const dynamic = 'force-dynamic';

export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const id = (await params).id;
  const user = await currentUser();
  if (!user) return Response.redirect(new URL(`/sign-in?next=${encodeURIComponent('/owner/documents')}`, req.url), 302);
  const f = (await ownerForms(user).catch(() => [])).find((x) => x.id === id);
  if (!f) return new Response('Not found', { status: 404 });
  const rows = f.data_sheet.map((r) => [r.label, r.value ?? 'To fill in']);
  const blocks: Block[] = [
    { t: 'title', text: `${f.form_code}${f.title ? `: ${f.title}` : ''}` },
    { t: 'p', text: `Data sheet for ${f.vehicle_name}. Copy each value onto the official form, in this order. Bring the form unsigned if you are not sure; we check it with you at the registry visit.` },
    ...(f.missing.length ? [{ t: 'p', text: `**Still missing:** ${f.missing.join(', ')}.` } as Block] : []),
    { t: 'table', head: ['Field', 'Value'], rows, kv: true }
  ];
  const pdf = await agreementPdf(blocks, { title: `${f.form_code} data sheet`, createdAt: new Date(f.generated_at), footer: `CarmaCars data sheet ${f.form_code} for ${f.vehicle_name}` });
  return new Response(pdf as unknown as BodyInit, { headers: { 'content-type': 'application/pdf', 'content-disposition': `inline; filename="${f.form_code}-data-sheet.pdf"`, 'cache-control': 'no-store' } });
}
