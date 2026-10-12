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
      'no-restricted-imports': ['error', { paths: [{ name: 'postgres', message: 'Use src/lib/db/repo.ts.' }] }]
    }
  },
  { files: ['src/lib/db/local.ts', 'src/lib/auth/local.ts', 'scripts/**', 'tests/**'], rules: { 'no-restricted-imports': 'off' } }
]);
