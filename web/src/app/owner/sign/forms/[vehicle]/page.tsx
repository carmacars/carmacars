import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { requireOwner } from '@/server/owner/data';
import { GovFormSign, type SignForm } from '@/features/onboarding/GovFormSign';
import { signSummary } from '@/features/onboarding/sign-state';
import { signGovernmentForms } from '@/server/actions/gov-forms-sign';
import '@/features/onboarding/onboarding.css';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign your government forms', path: '/owner/sign', noindex: true, description: 'Check and sign each government form for your car.' });

interface Data { vehicle_id: string; vehicle_name: string; plate: string | null; signer_name: string; due: boolean; forms: Array<SignForm & { fill: string }> }

// The owner signs each government (ServiceOntario) form their car needs (r35, 1000). Each form is the official PDF with only
// its boxes filled from the records; the signature is a record kept beside the form, never put on it.
export default async function OwnerSignForms({ params }: { params: Promise<{ vehicle: string }> }) {
  const { vehicle } = await params;
  if (!/^[0-9a-f-]{36}$/.test(vehicle)) notFound();
  const { user } = await requireOwner(`/owner/sign/forms/${vehicle}`);
  const data = (await rpc('owner_gov_forms_to_sign', { p_by: user.id, p: { vehicle_id: vehicle } }, { role: 'service_role' }).catch(() => null)) as unknown as Data | null;
  if (!data) notFound();
  const summary = signSummary(data.forms.map((f) => ({ sign_state: f.state, signable: f.signable })), 'owner');
  return (<>
    <header className="stack"><p className="pt-kicker"><Link prefetch={false} className="link" href="/owner/documents#ow-forms">Documents</Link></p>
      <h1 className="d2">Sign your government forms</h1>
      <p className="muted">{data.vehicle_name}{data.plate ? `, ${data.plate}` : ''}</p>
      <p data-testid="gov-form-sign-summary">{summary || 'Each form is filled in from your application and your car. Check it, then sign it.'}</p></header>
    {!data.due || data.forms.length === 0
      ? <p className="pt-card" data-testid="gov-form-sign-none">Your government forms are made as soon as your terms are approved. We will email you when they are ready to sign.</p>
      : <GovFormSign forms={data.forms} signerName={data.signer_name} action={(specs, input) => signGovernmentForms(vehicle, specs, input)} />}
  </>);
}
