import { PathSkeleton } from '@/components/loader/PathSkeleton';

// r48 speed: the shape of the page on its way, from its address (components/loader/PathSkeleton.tsx): one loading file for
// the pages below (a nested layout: its tabs keep the skeleton inside it), not one per page (each is an entry of its own in the Worker build)
export default function Loading() {
  return <PathSkeleton />;
}
