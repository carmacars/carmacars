import { LiveBooking } from '@/features/live/realtime/LiveBooking';

// r41: live updates for one booking's page and its sub pages (features/live/realtime/LiveBooking).
export default async function BookingLayout({ children, params }: { children: React.ReactNode; params: Promise<{ number: string }> }) {
  const { number } = await params;
  return <><LiveBooking number={decodeURIComponent(number)} />{children}</>;
}
