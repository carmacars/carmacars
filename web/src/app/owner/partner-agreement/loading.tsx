import { PageSkeleton } from '@/components/loader/skeletons';

// r48 speed: this page's shape while it loads (components/loader/skeletons.tsx; the look is BrandLoader's)
export default function Loading() {
  return <PageSkeleton shape="cards" />;
}
