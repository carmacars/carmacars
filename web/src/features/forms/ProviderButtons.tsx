import { connection } from 'next/server';
import { env } from '@/lib/env';
import { enabledProviders } from '@/lib/auth/oauth';
import { getTokensLite } from '@/lib/site';
import { OAuthButtons } from './OAuthButtons';

/** The provider buttons, read at request time (AUTH_OAUTH_PROVIDERS is a runtime switch, not baked into the build).
 *  Render inside <Suspense>. */
export async function ProviderButtons({ intent, next }: { intent: 'signin' | 'signup'; next?: string }) {
  await connection();
  const providers = enabledProviders(env().AUTH_OAUTH_PROVIDERS);
  const minAge = providers.length ? (await getTokensLite().catch(() => null))?.minAge : undefined;
  return <OAuthButtons providers={providers} intent={intent} next={next} minAge={minAge ?? undefined} />;
}
