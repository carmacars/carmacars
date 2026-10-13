import type { NextConfig } from 'next';
import { initOpenNextCloudflareForDev } from '@opennextjs/cloudflare';

const config: NextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  typedRoutes: false,
  // Images come pre-sized from the photo pipeline (docs/blueprint/09-listing-pipeline.md); no runtime
  // resizing in the Worker.
  images: { unoptimized: true },
  env: {
    NEXT_PUBLIC_DATA_BACKEND: process.env.DATA_BACKEND ?? 'local',
    NEXT_PUBLIC_TURNSTILE_PROVIDER: process.env.TURNSTILE_PROVIDER ?? 'fake'
  },
  // Server-only packages resolved from node_modules instead of being compiled into every route layer's
  // chunks: the Worker bundle (OpenNext, then wrangler) then holds one copy of each instead of two or three
  // (pdf-lib, zod and supabase-js were each bundled per layer; web/README.md, Worker size).
  serverExternalPackages: ['postgres', 'pdf-lib', 'zod', '@supabase/supabase-js', '@supabase/ssr', 'jose', 'aws4fetch'],
  async headers() {
    const noindex = [{ key: 'X-Robots-Tag', value: 'noindex, nofollow' }];
    return [
      { source: '/account/:path*', headers: noindex },
      { source: '/book/:path*', headers: noindex },
      { source: '/api/:path*', headers: noindex },
      ...['/admin', '/owner', '/va', '/field', '/investor', '/two-step', '/files', '/d'].flatMap((p) => [{ source: p, headers: noindex }, { source: `${p}/:path*`, headers: noindex }]),
      ...(process.env.APP_ENV === 'staging' ? [{ source: '/:path*', headers: noindex }] : [])
    ];
  },
  async redirects() {
    // The prototype's file names, in case one was shared.
    return [
      { source: '/fleet.html', destination: '/cars', permanent: true },
      { source: '/owners.html', destination: '/list-your-car', permanent: true },
      { source: '/signin.html', destination: '/sign-in', permanent: true },
      { source: '/sign-up', destination: '/create-account', permanent: true }
    ];
  }
};

if (process.env.NODE_ENV === 'development' && process.env.DATA_BACKEND === 'supabase') initOpenNextCloudflareForDev();

export default config;
