'use client';
import type { Official } from '@/features/official-forms/OfficialForm';
import { PackageSignForm, type PackageInput, type PackageResult, type Statement } from './PackageSignForm';
import type { SignatureValue } from './SignatureInput';

// The owner's signing package (migration 0049): the agreements and schedules, Forms A and B and the partner agreement are
// signed by the server; the official registry forms that are ready are filled and signed here in the browser with the
// same signature (as on their own page), then saved with the documents.
const b64 = (s: string) => Uint8Array.from(atob(s.replace(/^data:image\/png;base64,/, '')), (c) => c.charCodeAt(0));

/** A typed signature as an image, for the signature box of an official form: the name in a handwriting style. */
function typedPng(name: string): string {
  const c = document.createElement('canvas');
  c.width = 900; c.height = 200;
  const g = c.getContext('2d')!;
  g.fillStyle = '#1a1a2e';
  let size = 96;
  do { g.font = `italic ${size}px "Snell Roundhand", "Segoe Script", "Brush Script MT", cursive`; size -= 4; } while (g.measureText(name).width > 860 && size > 30);
  g.textBaseline = 'middle';
  g.fillText(name, 20, 105);
  return c.toDataURL('image/png');
}

async function signOfficial(forms: Official[], sig: SignatureValue): Promise<string | null> {
  if (!forms.length || !sig) return null;
  const png = b64(sig.method === 'drawn' ? sig.png : typedPng(sig.typedName));
  const { fillPdf } = await import('@/features/official-forms/fill');
  let ok = 0;
  for (const f of forms) {
    try {
      const t = await fetch(`/owner/documents/forms/${f.id}/template`);
      if (!t.ok) continue;
      const out = await fillPdf(await t.arrayBuffer(), f.field_values, f.field_map, { signaturePng: png, flatten: true });
      const r = await fetch(`/owner/documents/forms/${f.id}/signed`, { method: 'POST', headers: { 'content-type': 'application/pdf' }, body: out.bytes as unknown as BodyInit });
      const j = (await r.json().catch(() => ({ ok: false }))) as { ok: boolean };
      if (j.ok) ok++;
    } catch { /* that form stays open on its own page */ }
  }
  return ok === forms.length ? `The ${ok > 1 ? `${ok} registry forms are` : 'registry form is'} signed too.` : `${ok} of ${forms.length} registry forms signed; open the others in Documents.`;
}

export function OwnerPackage({ docs, signerName, statements, initials, officials, action, button, consent }: {
  docs: Array<{ key: string; title: string }>; signerName: string; statements: Statement[]; initials: boolean; officials: Official[];
  action: (input: PackageInput) => Promise<PackageResult>; button: string; consent: string;
}) {
  return (
    <PackageSignForm docs={docs} signerName={signerName} fixNameHref="/owner/profile" statements={statements} statementsLegend="The Owner confirms (Vehicle Enrollment Agreement)"
      initials={initials} consent={consent} button={button} action={action} after={(sig) => signOfficial(officials, sig)} testId="owner-package" />
  );
}
