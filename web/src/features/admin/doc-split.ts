// The identity review lists each driver's images under that driver. An image tied to nobody on the booking (a driver removed
// from it, or none recorded) is still counted by "Approve all" and approved by it (migration 0780: one rule for the count, the
// list and the approval), so it is listed too, under "Other documents".
export function otherUploads<U extends { driver_id: string | null }>(uploads: readonly U[], drivers: ReadonlyArray<{ driver_id: string }>): U[] {
  const known = new Set(drivers.map((d) => d.driver_id));
  return uploads.filter((u) => !u.driver_id || !known.has(u.driver_id));
}
