// The website's schema marker is the newest migration (src/lib/schema-marker.ts).
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import { SCHEMA_MARKER } from './schema-marker.ts';

test('the schema marker is the highest migration number', () => {
  const nums = readdirSync(join(import.meta.dirname, '../../../supabase/migrations')).map((f) => /^(\d{4})_/.exec(f)?.[1]).filter((x): x is string => !!x).sort();
  assert.equal(SCHEMA_MARKER, nums[nums.length - 1]);
});
