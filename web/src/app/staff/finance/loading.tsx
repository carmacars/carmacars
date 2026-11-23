import { PageSkeleton } from '@/components/loader/skeletons';

// r49 (3480): the Finance page's shape while it loads
export default function Loading() {
  return <PageSkeleton shape="table" />;
}
