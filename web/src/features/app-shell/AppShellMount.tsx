'use client';
import dynamic from 'next/dynamic';
import { useSyncExternalStore } from 'react';
import { inApp } from '@/lib/native/bridge';

// The store app's layer (migration 0390): nothing in a browser. Inside the CarmaCars app (the root layout's script marked
// <html data-shell="app"> and the native bridge is there) it loads AppShell, so browsers never download it.
const AppShell = dynamic(() => import('./AppShell'), { ssr: false });
const noop = () => () => undefined;

export function AppShellMount() {
  const on = useSyncExternalStore(noop, () => document.documentElement.dataset.shell === 'app' && inApp(), () => false);
  return on ? <AppShell /> : null;
}
