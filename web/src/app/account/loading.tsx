import { HeroSkeleton } from '@/components/portal-ui';
import { PathSkeleton } from '@/components/loader/PathSkeleton';

// While Trips loads: the shape of the trip hero and its cards (portal-ui); the pages below it get their own shape from the address
// (components/loader/PathSkeleton.tsx; r48: one loading file here, not one per page)
export default function Loading() {
  return <PathSkeleton only="^/account/?$"><HeroSkeleton /></PathSkeleton>;
}
