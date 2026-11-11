import { defineConfig, globalIgnores } from 'eslint/config';
import nextVitals from 'eslint-config-next/core-web-vitals';
import nextTs from 'eslint-config-next/typescript';

export default defineConfig([
  ...nextVitals,
  ...nextTs,
  globalIgnores(['.next/**', '.open-next/**', '.wrangler/**', 'node_modules/**', 'next-env.d.ts', 'public/**', 'test-results/**', 'reports/**']),
  {
    rules: {
      // Server-only code (service role, database driver) must never reach a client bundle.
      'no-restricted-imports': ['error', { paths: [{ name: 'postgres', message: 'Use src/lib/db/repo.ts.' },
        // Release 27: the shared Link does not scroll to the top on a tab, filter or page change; next/link does
        { name: 'next/link', message: "Import Link from '@/components/Link' (it keeps the scroll on same-page links)." }] }],
      // r35 engineering rules (docs/engineering-rules.md): no debug output in the app (warn and error only, never personal
      // data), and no string ever run as code
      'no-console': ['error', { allow: ['warn', 'error'] }],
      'no-eval': 'error',
      'no-implied-eval': 'error',
      'no-new-func': 'error'
    }
  },
  // a focused test (test.only) would silently skip every other test in CI
  { files: ['tests/**', 'src/**/*.test.ts'], rules: { 'no-restricted-properties': ['error',
    { object: 'test', property: 'only', message: 'Remove .only before committing.' },
    { object: 'describe', property: 'only', message: 'Remove .only before committing.' }] } },
  // tests print their measurements and run the inline scripts they test
  { files: ['scripts/**', 'tests/**', 'src/**/*.test.ts'], rules: { 'no-console': 'off', 'no-new-func': 'off' } },
  { files: ['src/components/Link.tsx'], rules: { 'no-restricted-imports': 'off' } },
  { files: ['src/lib/db/local.ts', 'src/lib/auth/local.ts', 'scripts/**', 'tests/**'], rules: { 'no-restricted-imports': 'off' } }
]);
