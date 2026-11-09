import { Card } from '@/features/admin/ui';

export interface FieldCall { starts_at: string; ends_at: string; applicant: string | null }
const time = (iso: string) => new Date(iso).toLocaleTimeString('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' });
const day = (iso: string) => new Date(iso).toLocaleDateString('en-CA', { timeZone: 'America/Toronto', weekday: 'long', month: 'long', day: 'numeric' });

// 1068: field applicants who passed the AI interview book a 10-minute live call in the hour before the weekly townhall,
// through their booking link (with the usual reminders). Fleet and Admin see the six slots and who took each one.
export function FieldCallsCard({ calls }: { calls: FieldCall[] }) {
  return (
    <Card title="Field applicant calls" testId="field-calls" aside={<span className="small">{day(calls[0]!.starts_at)}, before the townhall</span>}>
      <ol className="ad-list">{calls.map((c) => (
        <li key={c.starts_at}><span>{time(c.starts_at)} to {time(c.ends_at)}</span><b>{c.applicant ?? 'Open'}</b></li>))}</ol>
    </Card>
  );
}
