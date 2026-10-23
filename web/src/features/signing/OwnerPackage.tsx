'use client';
import { PackageSignForm, type PackageInput, type PackageResult, type Statement } from './PackageSignForm';

// The owner's signing package (migration 0049): the agreements and schedules, Forms A and B and the partner agreement are
// signed by the server. The official registry forms are not in it: they are printed and signed in ink (0122).
export function OwnerPackage({ docs, signerName, statements, initials, action, button, consent }: {
  docs: Array<{ key: string; title: string }>; signerName: string; statements: Statement[]; initials: boolean;
  action: (input: PackageInput) => Promise<PackageResult>; button: string; consent: string;
}) {
  return (
    <PackageSignForm docs={docs} signerName={signerName} fixNameHref="/owner/profile" statements={statements} statementsLegend="The Owner confirms (Vehicle Enrollment Agreement)"
      initials={initials} consent={consent} button={button} action={action} testId="owner-package" />
  );
}
