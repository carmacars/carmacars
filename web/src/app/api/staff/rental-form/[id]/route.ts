import { assertAdmin } from '@/server/admin/data';
import { door } from '@/server/door';
import { fileResponse } from '@/server/files';
import { companySignature, templateBytes } from '@/server/portal/blindspot';
import { layout } from '@/features/blindspot/layout';
import { fillBlindSpot } from '@/features/blindspot/fill';
import { sampleFacts } from '@/features/blindspot/sample';
import type { BlindSpotFacts } from '@/features/blindspot/layout';

// Admin > Settings > Forms: a per-booking form filled for a made-up booking (no real renter), with the mailing address,
// the HST number and the representative's signature of the settings, to check before it is used for bookings.
// ?insurer=1 fills the insurance replacement boxes too; ?blank=1 is the stored blank PDF itself.
export const dynamic = 'force-dynamic';
export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) return new Response('Not found', { status: 404 });
  let admin;
  try { admin = await assertAdmin(); } catch { return new Response('Not found', { status: 404 }); }
  type P = { file_key: string; sha256: string; form_code: string; version: string; mailing: BlindSpotFacts['extra']['mailing']; hst_number: string | null; rep: { name: string; signature_key: string | null } };
  const t = await door<P | null>(admin.id, 'ops_read', 'rental_form_preview', { template: id }).catch(() => null);
  if (!t?.file_key) return new Response('Not found', { status: 404 });
  const url = new URL(req.url);
  const tpl = await templateBytes(t);
  if (url.searchParams.get('blank') === '1') return fileResponse({ bytes: tpl, fileName: `${t.form_code}-${t.version}-blank.pdf`, contentType: 'application/pdf' });
  const facts = sampleFacts({ mailing: t.mailing, hst_number: t.hst_number }, { insurer: url.searchParams.get('insurer') === '1' });
  const out = await fillBlindSpot(tpl, layout(facts), { company: await companySignature(t.rep), title: `${t.form_code} sample` });
  return fileResponse({ bytes: out.bytes, fileName: `${t.form_code}-${t.version}-sample.pdf`, contentType: 'application/pdf' });
}
