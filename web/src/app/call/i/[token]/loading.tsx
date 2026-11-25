import { PageSkeleton } from '@/components/loader/skeletons';

// r50 design zero: the interview call page's shape while it loads (no blank screen; components/loader/skeletons.tsx)
export default function Loading() {
  return <PageSkeleton shape="form" />;
}
