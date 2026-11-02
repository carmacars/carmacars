import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Card, Kv, PageHead } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My profile', path: '/admin/settings/profile', noindex: true, description: 'How To do and the assistant greet you.' });

// Settings > My profile (migration 0324): the greeting name of the signed-in Admin. To do and the staff assistant greet
// it whole ("Abbas and Mahad" for a login the owners share); empty, the first name of the account.
export default async function MyProfile() {
  const { read } = await page('/admin/settings/profile');
  const p = await read<{ email: string; name: string | null; greeting_name: string | null; greeting: string | null }>('my_profile');
  return (
    <>
      <PageHead title="My profile" kicker={<Link prefetch={false} className="link" href="/admin/settings">Settings</Link>} purpose="How To do and the assistant greet you on this login." />
      <Card title="Greeting" testId="my-profile">
        <Kv rows={[['Account', p.email], ['Account name', p.name ?? 'Not set'], ['Greeting name', p.greeting_name ?? 'Not set: the account name is used']]} />
        <Act action="my_greeting_save" label="Change the greeting name" variant="primary" title="Greeting name" submitLabel="Save" testId="my-greeting" refresh={['/admin', '/admin/settings/profile']}
          done="Saved. To do greets this name now."
          fields={[{ name: 'greeting_name', label: 'Greeting name', value: p.greeting_name ?? '', placeholder: 'For example: Abbas and Mahad',
            hint: 'Shown whole on To do ("Good morning, Abbas and Mahad") and in the assistant. Empty: the first name of the account.' }]} />
      </Card>
    </>
  );
}
