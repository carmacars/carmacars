// Buckets of docs/architecture.md section 6. Only vehicle-public is public; every other bucket is
// private and reached through short-lived signed links issued after row-level security has passed.
export type Bucket = 'vehicle-public' | 'vehicle-originals' | 'documents' | 'identity' | 'condition-photos';

export interface StorageAdapter {
  readonly name: 'r2' | 'local';
  /** Address of a file in the public bucket (vehicle photos, site photos). */
  publicUrl(path: string): string;
  signedDownloadUrl(bucket: Bucket, key: string, ttlSeconds?: number): Promise<string>;
  signedUploadUrl(bucket: Bucket, key: string, contentType: string, ttlSeconds?: number): Promise<{ url: string; headers: Record<string, string> }>;
}
