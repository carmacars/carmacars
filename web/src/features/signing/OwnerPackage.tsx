'use client';
import { PackageSignForm, type PackageInput, type PackageResult, type Statement } from './PackageSignForm';
import type { EsignDoc } from './types';

// The owner's signing package (migration 0049): the agreements and schedules, Forms A and B and the partner agreement are
// signed by the server, with the signing steps of every signature (0193: the code, the reading, the Enrollment
// Agreement's confirmations initialled, the consents, the drawn signature). The official registry forms are not in it:
// they are printed and signed in ink (0122).
export function OwnerPackage({ docs, signerName, statements, esignDocs, role, action, button, consent }: {
  docs: Array<{ key: string; title: string }>; signerName: string; statements: Statement[]; esignDocs: EsignDoc[]; role: 'owner' | 'partner';
  action: (input: PackageInput) => Promise<PackageResult>; button: string; consent: string;
}) {
  return (
    <PackageSignForm docs={docs} signerName={signerName} statements={statements} esign={{ kind: 'documents', docs: esignDocs, role }}
      consent={consent} button={button} action={action} testId="owner-package" />
  );
}
