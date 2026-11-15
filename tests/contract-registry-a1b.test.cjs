const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Registry = require('../js/akatsuki-contract-registry.js');

const migration = fs.readdirSync(path.join(__dirname, '../supabase/migrations'))
  .find(name => name.endsWith('_contract_registry_registration.sql'));
assert(migration, 'A1B migration required');
const sql = fs.readFileSync(path.join(__dirname, '../supabase/migrations', migration), 'utf8');
assert.match(sql, /security definer\s+set search_path = ''/i);
assert.match(sql, /v_owner uuid := auth\.uid\(\)/);
assert.match(sql, /on conflict \(user_id,app_key\) do nothing/);
assert.match(sql, /on conflict \(user_id,service_key\) do nothing/);
assert.match(sql, /revoke all on function public\.akatsuki_contract_register\(text,jsonb\) from public, anon, authenticated/);
assert.match(sql, /grant execute on function public\.akatsuki_contract_register\(text,jsonb\) to authenticated/);
assert.doesNotMatch(sql, /grant\s+(?:all|insert|update|delete)\s+on\s+public\.akatsuki_contract_/i);

const calls=[];
let offline=false;
const client={
  rpc:async (name,args)=>{calls.push({name,args});return offline?{error:new Error('offline')}:{data:{status:'created'}};},
  from:table=>{const request={
    select(){return request;},eq(k,v){calls.push({filter:[k,v]});return request;},
    in(k,v){calls.push({in:[k,v]});return request;},order(k){calls.push({order:k});return request;},
    then(resolve){resolve({data:[{table}],error:offline?new Error('offline'):null});}
  };calls.push({table});return request;}
};
(async()=>{
  const api=Registry(client);
  assert.deepEqual(await api.registerApp({app_key:'catalyst',name:'Catalyst'}),{status:'created'});
  assert.equal(calls[0].args.p_kind,'app');
  assert.equal(calls[0].args.p_metadata.app_key,'catalyst');
  await api.registerService({service_key:'shared-vocabulary',name:'Vocabulary'});
  assert.equal(calls[1].args.p_kind,'service');
  assert.deepEqual((await api.listApps())[0],{table:'akatsuki_contract_apps'});
  assert.deepEqual((await api.listServices())[0],{table:'akatsuki_contract_services'});
  await api.listContracts('shared-vocabulary');
  assert(calls.some(x=>x.in?.[0]==='lifecycle' && x.in[1].join() === 'published,deprecated'));
  assert.throws(()=>api.listContracts(''),/Valid service key/);
  await assert.rejects(()=>api.registerApp([]),/metadata must be an object/);
  offline=true;
  await assert.rejects(()=>api.registerService({name:'offline'}),/offline/);
  await assert.rejects(()=>api.listApps(),/offline/);
  console.log('PASS A1B registry RPC/discovery, published-only filter, error propagation and security structure');
})().catch(e=>{console.error(e);process.exitCode=1;});
