import 'server-only';
import { env, required } from '@/lib/env';
import { linkSecret } from '@/server/links';
import type { StorageAdapter } from './types';

let cached: StorageAdapter | undefined;
export async function storage(): Promise<StorageAdapter> {
  if (cached) return cached;
  const e = env();
  if (e.STORAGE_PROVIDER === 'r2') {
    const { r2Storage } = await import('./r2');
    cached = r2Storage({ accountId: required('R2_ACCOUNT_ID'), accessKeyId: required('R2_ACCESS_KEY_ID'), secretAccessKey: required('R2_SECRET_ACCESS_KEY'), bucketPrefix: e.R2_BUCKET_PREFIX, publicBase: e.NEXT_PUBLIC_VEHICLE_PHOTOS_URL });
  } else {
    const { localStorageAdapter } = await import('./local');
    cached = localStorageAdapter(e.NEXT_PUBLIC_VEHICLE_PHOTOS_URL, linkSecret());
  }
  return cached;
}
export type * from './types';
