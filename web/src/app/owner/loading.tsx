import { PathSkeleton } from '@/components/loader/PathSkeleton';

// r48 speed: the shape of the page on its way, from its address (components/loader/PathSkeleton.tsx): one loading file for
// the pages below, not one per page (each is an entry of its own in the Worker build)
export default function Loading() {
  return <PathSkeleton />;
}
