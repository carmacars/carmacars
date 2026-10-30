'use client';
import { createContext, useContext, type ReactNode } from 'react';
import { adminAct, adminPreview, adminSaveRow } from '@/server/actions/admin-portal';
import { vaAct, vaPreview } from '@/server/actions/va';

// Which door the shared working screens go through (migration 0031): the Admin's, or an assistant's.
// The same screens (Act, BookingReview, MasterCalendar, ListingReview, TollImport) run either way; the
// database decides what each may do, and the screens hide what an assistant cannot use.
export type DoorKind = 'admin' | 'va';
const Ctx = createContext<DoorKind>('admin');

export function DoorProvider({ kind, children }: { kind: DoorKind; children: ReactNode }) {
  return <Ctx.Provider value={kind}>{children}</Ctx.Provider>;
}

export function useDoor() {
  const kind = useContext(Ctx);
  return kind === 'va'
    ? { kind, act: vaAct, preview: vaPreview, save: adminSaveRow, base: '/staff' }
    : { kind, act: adminAct, preview: adminPreview, save: adminSaveRow, base: '/admin' };
}
