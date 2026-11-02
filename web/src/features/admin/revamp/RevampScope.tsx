'use client';
import './revamp.css';
import { usePathname } from 'next/navigation';
import { revamped } from './scope';

// Wraps a portal's page in the revamped look when the page is in the list (scope.ts). The wrapper takes no space
// (display: contents), so the page's own layout is unchanged; only its tables, tiles, cards, chips and badges restyle.
export function RevampScope({ list, children }: { list: string[]; children: React.ReactNode }) {
  const path = usePathname() ?? '';
  return <div className={revamped(list, path) ? 'rv' : 'rv-off'} style={{ display: 'contents' }} data-revamp={revamped(list, path) ? '' : undefined}>{children}</div>;
}
