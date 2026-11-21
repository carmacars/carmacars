'use client';
import { useEffect } from 'react';
import { runSharer } from './share';

// Mounted once in the staff, renter and owner portals (migration 3350): shares this person's location with the live map
// only while the database says they qualify, and only once this device allowed it. Draws nothing.
export function LocationSharer() {
  useEffect(() => runSharer(), []);
  return null;
}
