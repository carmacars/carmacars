'use client';
import { useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { adminToast } from '@/features/admin/shell/toast';
import { financeFeedSync } from '@/server/actions/finance';

// Release 49 (3480): pull the live bank feed now (shown only when Program setting bank_data_provider is a feed).
export function FeedSync({ provider }: { provider: string }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  return (
    <button type="button" className="btn btn--sm btn--ghost" disabled={pending} aria-busy={pending} data-testid="bank-feed-sync"
      onClick={() => start(async () => {
        const r = await financeFeedSync();
        if (r.ok) { adminToast(`${r.data.lines_new} new line(s) from the ${provider} feed, ${r.data.lines_matched} matched.`); router.refresh(); }
        else adminToast(r.message, 'error');
      })}>{pending ? 'Pulling...' : 'Pull the bank feed now'}</button>
  );
}
