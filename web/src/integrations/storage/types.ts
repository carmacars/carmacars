// Buckets of docs/architecture.md section 6. Only vehicle-public is public; every other bucket is
// private and reached through short-lived signed links issued after row-level security has passed.
export type Bucket = 'vehicle-public' | 'vehicle-originals' | 'documents' | 'identity' | 'condition-photos' | 'agreements';
export const PRIVATE_BUCKETS: readonly Bucket[] = ['vehicle-originals', 'documents', 'identity', 'condition-photos', 'agreements'];

export interface StorageAdapter {
  readonly name: 'r2' | 'local';
  /** Address of a file in the public bucket (vehicle photos, site photos). */
  publicUrl(path: string): string;
  /** A GET link valid for ttlSeconds; downloads carry Content-Disposition: attachment when a filename is given. */
  signedDownloadUrl(bucket: Bucket, key: string, ttlSeconds?: number, filename?: string): Promise<string>;
  /** A PUT link bound to the key and the content type, valid for ttlSeconds (the browser uploads straight to storage). */
  signedUploadUrl(bucket: Bucket, key: string, contentType: string, ttlSeconds?: number): Promise<{ url: string; headers: Record<string, string> }>;
  /** Server side: write, read and delete an object. */
  put(bucket: Bucket, key: string, body: Uint8Array, contentType: string): Promise<void>;
  get(bucket: Bucket, key: string): Promise<Uint8Array | null>;
  remove(bucket: Bucket, key: string): Promise<void>;
}
