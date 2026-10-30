import { Suspense } from 'react';
import { GroupNav } from '@/features/admin/GroupNav';
import { staffNav } from '@/features/staff/nav';

// The staff portal's menu (0197): the groups of every function the person holds (src/features/staff/nav.ts).
export function StaffNav({ functions, open, chat = 0, hot = 0 }: { functions: readonly string[]; open: number; chat?: number; hot?: number }) {
  return (
    <Suspense fallback={<nav className="gn" aria-label="Staff" />}>
      <GroupNav groups={staffNav(functions)} counts={{ '/staff': open, '/staff/chat': chat, '/staff/live': hot }} label="Staff" testId="va-nav" />
    </Suspense>
  );
}
