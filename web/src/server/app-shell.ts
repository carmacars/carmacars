import 'server-only';
import { headers } from 'next/headers';
import { appShellOf, type AppShell } from '@/lib/native/shell';

// The store app (migration 0390): this request comes from the CarmaCars app's WebView (its user agent token,
// apps/carmacars/capacitor.config.ts). For dynamic pages only (reading the headers makes a page dynamic): the alerts
// card and the profile's app settings. Static pages mark the app in the browser instead (the root layout's script).
export async function appShell(): Promise<AppShell | null> {
  try { return appShellOf((await headers()).get('user-agent')); } catch { return null; }
}

export async function inAppShell(): Promise<boolean> {
  return (await appShell()) !== null;
}
