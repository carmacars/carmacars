import { Act } from '@/features/admin/Act';
import { door } from '@/server/door';
import { MONTHS, birthdayWords } from './birthday';

// r50 (4600): the optional birthday (month and day, no year) on the staff profile; the weekly townhall shows it.
export async function BirthdaySection({ userId, portal, className, refresh }: { userId: string; portal: 'va' | 'field'; className: string; refresh: string[] }) {
  const b = await door<{ month: number | null; day: number | null } | null>(userId, portal === 'field' ? 'field_read' : 'ops_read', 'staff_birthday', {}).catch(() => null);
  if (!b) return null;
  const words = birthdayWords(b.month, b.day);
  return (
    <section className={className} aria-labelledby="bd-t" data-testid="profile-birthday"><h2 className="d4" id="bd-t">Birthday</h2>
      <p className="small">{words ? `${words}. The team wishes you a happy birthday at the townhall.` : 'Optional: add the month and day (no year) and the team celebrates it at the townhall.'}</p>
      <div><Act ops action="staff_birthday_save" label={words ? 'Change my birthday' : 'Add my birthday'} title="Your birthday" submitLabel="Save" testId="profile-birthday-save" refresh={refresh} done="Saved."
        fields={[{ name: 'month', label: 'Month', type: 'select', value: b.month ? String(b.month) : '', options: [['', 'None'], ...MONTHS.map((m, i) => [String(i + 1), m] as [string, string])] },
          { name: 'day', label: 'Day', type: 'number', min: 1, max: 31, value: b.day ?? '' }]} /></div>
    </section>
  );
}
