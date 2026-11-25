// Static safety checks for the optional isolated SQL rehearsal. This does NOT execute PostgreSQL.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const sql = fs.readFileSync(path.join(__dirname, 'contract-registry-a1e-isolated-gate.sql'), 'utf8');
assert.match(sql, /\bBEGIN;/);
assert.match(sql, /\bROLLBACK;/);
assert.match(sql, /current_database\(\) !~ '\^akatsuki_a1e_/);
assert.match(sql, /inet_server_addr\(\)/);
assert.match(sql, /SET LOCAL ROLE authenticated;/);
assert.match(sql, /SET LOCAL ROLE anon;/);
assert.match(sql, /has_function_privilege\('anon'/);
// PostgreSQL stores SET search_path = '' as search_path="" in proconfig.
// Avoid brittle equality against the raw proconfig array element.
assert.match(sql, /pg_options_to_table\(p\.proconfig\)/);
assert.match(sql, /cfg\.option_name='search_path'/);
assert.match(sql, /cfg\.option_value IN \('', '""'\)/);
assert.doesNotMatch(sql, /'search_path='=ANY\(p\.proconfig\)/);
assert.match(sql, /pg_policies/);
assert.match(sql, /Cross-owner app visibility leaked/);
assert.match(sql, /Anonymous registration unexpectedly allowed/);
assert.match(sql, /Authenticated table INSERT unexpectedly accepted/);
assert.match(sql, /Privileged metadata unexpectedly accepted/);
assert.doesNotMatch(sql, /\b(?:DROP|TRUNCATE|ALTER TABLE|CREATE TABLE|COMMIT)\b/i,
  'A1E staging test must not change schemas or commit data');
assert.doesNotMatch(sql, /\b(?:akatsuki_tasks|akatsuki_broadcasts)\b/i,
  'A1E staging test must not touch legacy task or broadcast tables');
console.log('PASS A1E staging-only guard, browser grants, owner tests and rollback safety structure');
