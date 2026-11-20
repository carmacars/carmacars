import { useEffect } from 'react';
import { usePathname, useRouter } from 'expo-router';
import { useApp } from '@/app-state';
import { Button, Empty, Screen } from '@/ui/kit';

// A link the app has no screen for: when it is a page of the site, it opens in the in-app browser.
export default function NotFound() {
  const path = usePathname();
  const router = useRouter();
  const { open } = useApp();
  // a path of the site typed or linked inside the app: the same rule as a link from outside
  useEffect(() => { if (path && path !== '/' && !path.startsWith('/web')) open(path); }, [path, open]);
  return <Screen><Empty title="This page opens on carmacars.ca" body="We opened it in the browser inside the app." action={<Button label="Back to the app" onPress={() => router.replace('/')} />} /></Screen>;
}
