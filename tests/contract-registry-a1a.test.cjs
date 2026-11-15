const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const migrations = fs.readdirSync(path.join(__dirname, '../supabase/migrations'))
  .filter(name => name.endsWith('_contract_registry_foundation.sql'));
assert.equal(migrations.length, 1, 'exactly one A1A migration');
const sql = fs.readFileSync(path.join(__dirname, '../supabase/migrations', migrations[0]), 'utf8');
const tables = ['akatsuki_contract_apps', 'akatsuki_contract_services', 'akatsuki_contract_versions'];
for (const name of tables) {
  assert.match(sql, new RegExp(`create table public\\.${name} \\(`));
  assert.match(sql, new RegExp(`alter table public\\.${name} enable row level security;`));
  assert.match(sql, new RegExp(`revoke all on public\\.${name} from public, anon, authenticated;`));
  assert.match(sql, new RegExp(`grant select on public\\.${name} to authenticated;`));
  assert.match(sql, new RegExp(`on public\\.${name} for select to authenticated\\s+using \\(user_id = \\(select auth\\.uid\\(\\)\\)\\)`));
}
assert.match(sql, /foreign key \(user_id, service_key\)/);
assert.doesNotMatch(sql, /\b(?:alter|drop|truncate|update|delete from)\s+(?:table\s+)?(?:public\.)?akatsuki_(?!contract_)/i,
  'A1A must not mutate legacy Akatsuki tables');
assert.doesNotMatch(sql, /grant\s+(?:all|insert|update|delete)\s+on/i, 'no browser write grants');
console.log('PASS A1A isolated table declarations, owner RLS, read-only grants, legacy protection');
