import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, Card, Kv, PageHead, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Meta publishing', path: '/admin/settings/meta-publishing', noindex: true, description: 'Publishing approved drafts to the Facebook Page and Instagram through Meta: off until the tokens are entered.' });
type Data = { enabled: boolean; usable: boolean; page_id: string | null; ig_user_id: string | null; graph_version: string; has_token: boolean; token_hint: string | null; token_store: string | null;
  last_ok_at: string | null; last_error: string | null; updated_at: string; posted_by_api: number };

// Admin > Settings > Meta publishing (migration 0167, the spec's task 7): approved drafts posted to the Facebook Page and
// Instagram by Meta's Graph API. Built, and off: nothing goes to Meta until an Admin enters the Page id, the Instagram
// professional account id and a Page access token (kept in Supabase Vault; this page shows only its last four characters)
// and switches it on. Until then drafts are copied and posted by hand.
export default async function MetaPublishing() {
  const { read } = await page('/admin/settings/meta-publishing');
  const m = await read<Data>('meta_publishing');
  const refresh = ['/admin/settings/meta-publishing', '/admin/marketing/social'];
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/settings">Settings</Link>} title="Meta publishing"
      purpose="Post approved drafts to the Facebook Page and Instagram automatically. Off until you enter the Page id, the Instagram account id and a Page access token." />
    <Card title="Connection" testId="meta-settings" aside={m.usable ? <Badge s="published">On</Badge> : <Badge s="draft">{m.enabled ? 'Not ready' : 'Off'}</Badge>}>
      <Kv rows={[['Facebook Page id', m.page_id ?? 'Not set'], ['Instagram account id', m.ig_user_id ?? 'Not set (Instagram posts stay by hand)'], ['Page access token', m.has_token ? `Set, ending ${m.token_hint ?? ''} (${m.token_store === 'vault' ? 'in the vault' : 'stored'})` : 'Not set'],
        ['Graph API version', m.graph_version], ['Publishing', m.usable ? 'On: approved posts go out on their day' : 'Off: copy and post by hand'], ['Posts published through Meta', String(m.posted_by_api)],
        ['Last success', m.last_ok_at ? t(m.last_ok_at) : null], ['Last refusal', m.last_error]]} />
      <div className="row" style={{ gap: '0.5rem', flexWrap: 'wrap' }}>
        <Act action="meta_publishing_save" label={m.has_token ? 'Change the details' : 'Enter the details'} variant="primary" testId="meta-save" refresh={refresh} done="Saved."
          fields={[{ name: 'page_id', label: 'Facebook Page id (digits)', type: 'text', value: m.page_id }, { name: 'ig_user_id', label: 'Instagram professional account id (digits)', type: 'text', value: m.ig_user_id },
            { name: 'token', label: m.has_token ? 'New Page access token (leave empty to keep the one set)' : 'Page access token', type: 'text', wide: true },
            { name: 'graph_version', label: 'Graph API version', type: 'text', value: m.graph_version }]} />
        {m.has_token && m.page_id && <Act action="meta_publishing_save" payload={{ enabled: !m.enabled }} label={m.enabled ? 'Switch off' : 'Switch on'} testId="meta-toggle" refresh={refresh}
          done={m.enabled ? 'Off: posts are copied by hand.' : 'On: approved posts go out on their day.'} confirm={m.enabled ? undefined : 'Approved drafts will be posted to the Page (and Instagram) on their day without anyone pressing a button. Switch on?'} />}
        {m.has_token && <Act action="meta_publishing_save" payload={{ token: '-', enabled: false }} label="Remove the token" variant="danger" refresh={refresh} done="Token removed; publishing is off." confirm="Remove the token from the vault and switch publishing off?" />}
      </div>
    </Card>
    <Card title="What the owner sets up at Meta (once)" testId="meta-steps">
      <ol className="small">
        <li>Make the Instagram account a professional (business or creator) account and link it to the CarmaCars Facebook Page (Instagram settings, then Account type and tools; and the Page&apos;s Linked accounts).</li>
        <li>At developers.facebook.com, create an app of the Business type owned by the CarmaCars business portfolio. Add the products Facebook Login for Business and Instagram.</li>
        <li>In the Graph API Explorer of that app, choose the Page and ask for the permissions pages_show_list, pages_read_engagement, pages_manage_posts, instagram_basic and instagram_content_publish. Generate a Page access token, then exchange it for a long-lived one (the Access Token Debugger shows its expiry; a Page token from a long-lived user token does not expire while the person stays an admin of the Page).</li>
        <li>Read the ids: the Page id is in the Page&apos;s About section (Page transparency); the Instagram account id is the instagram_business_account field of the Page in the Graph API Explorer.</li>
        <li>For posts seen by the public the app must be in Live mode; Meta may ask for App Review of instagram_content_publish and pages_manage_posts before that.</li>
        <li>Enter the two ids and the token above, then press Switch on. The token goes to the vault; this page shows only its last four characters.</li>
      </ol>
      <p className="small muted">How it posts: the Facebook Page gets the caption with its tracked link and the draft&apos;s first photo; Instagram gets the first photo and the caption (Instagram takes 100 posts in 24 hours, far more than the plan uses). Carousels are posted by hand. A refusal is shown on the draft and here, and the draft is tried at most 3 times. Facebook Marketplace is never posted from here: Meta does not take vehicle listings from business Pages.</p>
    </Card>
  </>);
}
