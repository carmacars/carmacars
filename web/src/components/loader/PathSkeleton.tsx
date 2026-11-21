'use client';
import type { ReactNode } from 'react';
import { usePathname } from 'next/navigation';
import { PageSkeleton, shapeFor } from './skeletons';

/** r48: the one loading.tsx of a portal (and of each nested layout) shows the shape of the page on its way, read from the
 *  address by shapeFor, the same shape RouteProgress shows on the tap. One file per portal instead of one per page: each
 *  loading.tsx is its own entry in the server build, and 288 of them added about 8 MiB to the Worker (scripts/worker-size.mjs).
 *  `children`, when given, is shown instead on the address `only` matches (a page with a skeleton of its own). */
export function PathSkeleton({ only, children }: { only?: string; children?: ReactNode }) {
  const path = usePathname() ?? '';
  if (children && only && new RegExp(only).test(path)) return <>{children}</>;
  return <PageSkeleton shape={shapeFor(path)} />;
}
