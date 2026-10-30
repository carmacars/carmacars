import 'server-only';
import { env } from '@/lib/env';
import { zip } from '@/lib/zip';
import { bytes, cmsSignedData, iconPng, passJson, pemToDer, signedAttrs, type PassFacts } from '@/features/wallet/pkpass';

// Apple Wallet passes for a confirmed booking (Release 22). Signing needs CarmaCars' own Pass Type ID certificate from the
// Apple Developer account; until the five WALLET_* values are set, walletReady() is false: the button is hidden and Admin >
// Settings lists the step under setup.
export function walletReady(): boolean {
  const e = env();
  return !!(e.WALLET_PASS_CERT && e.WALLET_PASS_KEY && e.WALLET_WWDR_CERT && e.WALLET_PASS_TYPE_ID && e.WALLET_TEAM_ID);
}

const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, '0')).join('');
const pem = (v: string) => v.replace(/\\n/g, '\n');
const buf = (b: Uint8Array) => new Uint8Array(b);

export async function buildPass(f: PassFacts): Promise<Uint8Array> {
  const e = env();
  if (!walletReady()) throw new Error('Apple Wallet is not set up');
  const files: Array<{ name: string; data: Uint8Array }> = [
    { name: 'pass.json', data: bytes(JSON.stringify(passJson(f, { passTypeId: e.WALLET_PASS_TYPE_ID!, teamId: e.WALLET_TEAM_ID! }))) },
    { name: 'icon.png', data: iconPng(29) }, { name: 'icon@2x.png', data: iconPng(58) }, { name: 'icon@3x.png', data: iconPng(87) },
    { name: 'logo.png', data: iconPng(50) }, { name: 'logo@2x.png', data: iconPng(100) }
  ];
  const manifest: Record<string, string> = {};
  for (const x of files) manifest[x.name] = hex(await crypto.subtle.digest('SHA-1', buf(x.data)));
  const manifestBytes = bytes(JSON.stringify(manifest));
  const at = new Date();
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', buf(manifestBytes)));
  const key = await crypto.subtle.importKey('pkcs8', buf(pemToDer(pem(e.WALLET_PASS_KEY!))), { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const signature = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, buf(signedAttrs(digest, at))));
  const cms = cmsSignedData({ signerCert: pemToDer(pem(e.WALLET_PASS_CERT!)), chain: [pemToDer(pem(e.WALLET_WWDR_CERT!))], digest, at, signature });
  return zip([...files, { name: 'manifest.json', data: manifestBytes }, { name: 'signature', data: cms }]);
}
