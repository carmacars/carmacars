'use client';
import { Fragment, Suspense, type ReactNode } from 'react';
import { usePathname, useRouter, useSearchParams } from 'next/navigation';
import { parseSort, sortItems, SORT_LABEL, type SortKey, type SortValues } from '@/lib/sort';

// r43: the sort of every table in the Admin and staff portals. The rows are drawn on the server (their cells are
// server-made), this reorders them by the ?sort= of the address: Newest first, Oldest first, Recently active, A to Z.
// Only the sort is in the address, nothing personal. A list that has no dates is left alone (the Table decides).
export interface SortItem { k: string; v: SortValues; node: ReactNode }

function useSort(def: SortKey | null): SortKey | null {
  const sp = useSearchParams();
  return parseSort(sp.get('sort')) ?? def;
}

function Rows({ items, def }: { items: SortItem[]; def: SortKey | null }) {
  const sort = useSort(def);
  return <>{sortItems(items, sort, (i) => i.v).map((i) => <Fragment key={i.k}>{i.node}</Fragment>)}</>;
}

/** The table body in the chosen order. The first paint (and a browser without the address) keeps the server's order. */
export function SortedBody({ items, def }: { items: SortItem[]; def: SortKey | null }) {
  return (
    <tbody role="rowgroup">
      <Suspense fallback={items.map((i) => <Fragment key={i.k}>{i.node}</Fragment>)}><Rows items={items} def={def} /></Suspense>
    </tbody>
  );
}

function Select({ options, def, label }: { options: SortKey[]; def: SortKey | null; label: string }) {
  const sp = useSearchParams();
  const path = usePathname();
  const router = useRouter();
  const value = parseSort(sp.get('sort')) ?? def ?? options[0]!;
  const change = (v: string) => {
    const q = new URLSearchParams(sp.toString());
    q.set('sort', v);
    router.replace(`${path}?${q.toString()}`, { scroll: false });
  };
  return (
    <label className="ad-sort small">
      <span className="muted">{label}</span>{' '}
      <select className="select select--sm" value={value} onChange={(e) => change(e.target.value)} data-testid="sort-select" aria-label={label}>
        {options.map((o) => <option key={o} value={o}>{SORT_LABEL[o]}</option>)}
      </select>
    </label>
  );
}

/** The sort control above a list: a select of the sorts the list offers; the choice goes to ?sort= only. */
export function SortSelect({ options, def = null, label = 'Sort' }: { options: SortKey[]; def?: SortKey | null; label?: string }) {
  if (!options.length) return null;
  return <Suspense fallback={null}><Select options={options} def={def} label={label} /></Suspense>;
}
