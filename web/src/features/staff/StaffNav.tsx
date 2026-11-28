import { Suspense } from 'react';
import { GroupNav } from '@/features/admin/GroupNav';
import { staffNav } from '@/features/staff/nav';

// The staff portal's menu (0197): the groups of every function the person holds (src/features/staff/nav.ts).
export function StaffNav({ functions, open, chat = 0, hot = 0, manager = false }: { functions: readonly string[]; open: number; chat?: number; hot?: number; /** 5302 */ manager?: boolean }) {
  return (
    <Suspense fallback={<nav className="gn" aria-label="Staff" />}>
      <GroupNav groups={staffNav(functions, { manager })} counts={{ '/staff': open, '/staff/visitors': chat + hot }} label="Staff" testId="va-nav" alwaysOpen={[...functions]} />
    </Suspense>
  );
}
