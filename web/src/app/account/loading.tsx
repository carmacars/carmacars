import { PageSkeleton } from '@/components/PageSkeleton';

export default function Loading() {
  return <PageSkeleton cards={3} label="Loading your account" />;
}
