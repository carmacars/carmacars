// r32 "Simple": the booking page in six sections, the same for Admin and staff. The old tabs (?tab=review, changes,
// messages, history, ...) land in the section that holds them now, so every saved link and guide address still works.
export type BookingSection = 'overview' | 'money' | 'documents' | 'car' | 'activity' | 'extras';

export const BOOKING_SECTIONS: ReadonlyArray<readonly [BookingSection, string]> = [
  ['overview', 'Overview'],
  ['money', 'Money'],
  ['documents', 'Drivers & documents'],
  ['car', 'Car & handovers'],
  ['activity', 'Messages & history'],
  ['extras', 'Claims & extras'],
];

/** The old tab names and where each one lives now. */
export const OLD_TAB: Record<string, BookingSection> = {
  review: 'overview', overview: 'overview', money: 'money', documents: 'documents', drivers: 'documents',
  handover: 'car', report: 'car', car: 'car', messages: 'activity', history: 'activity', activity: 'activity',
  changes: 'extras', extras: 'extras', claims: 'extras',
};

export function bookingSection(tab: string | null | undefined): BookingSection {
  return (tab && OLD_TAB[tab]) || 'overview';
}

/** Whether an old tab's content shows in the section open now (the overview is the review while an offer is being arranged). */
export function shows(section: BookingSection, oldTab: string, arranging: boolean): boolean {
  if (oldTab === 'review') return section === 'overview' && arranging;
  if (oldTab === 'overview') return section === 'overview' && !arranging;
  return OLD_TAB[oldTab] === section;
}
