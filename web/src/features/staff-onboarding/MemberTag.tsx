'use client';
import { CopyText } from '@/features/ads/CopyText';
import { TAG_STEPS } from './model';

// r48 FE (3191): the member tag a staff member sets in each WhatsApp group, written for them ("Darren - Sales"), with Copy
// and the steps. Shown next to each group link.
export function MemberTag({ tag, testId }: { tag: string; testId?: string }) {
  return (
    <div className="stack" data-testid={testId}>
      <CopyText label="Member tag" value={tag} testId={testId ? `${testId}-value` : undefined} />
      <ol className="small">{TAG_STEPS.map((s) => <li key={s}>{s}</li>)}</ol>
    </div>
  );
}
