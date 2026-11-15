const assert = require('node:assert/strict');
const test = require('node:test');
const view = require('../js/akatsuki-contracts-view.js');

test('signed-out registry stays empty and performs no query', async () => {
  let called = false;
  const result = await view.adapter(() => { called = true; }).load(null);
  assert.equal(result.status, 'signed-out');
  assert.deepEqual(result.apps, []);
  assert.equal(called, false);
});

test('missing A1A table is a clear nonfatal unavailable state', async () => {
  const result = await view.adapter(() => ({
    listApps: async () => { throw { code: 'PGRST205', message: 'Table unavailable' }; },
    listServices: async () => []
  })).load({});
  assert.equal(result.status, 'unavailable');
  assert.match(result.message, /not deployed/);
});

test('ready registry shows real data and never invents sample apps', async () => {
  const result = await view.adapter(() => ({ listApps: async () => [], listServices: async () => [{ service_key: 'language' }] })).load({});
  assert.equal(result.status, 'ready');
  assert.deepEqual(result.apps, []);
  assert.equal(result.services[0].service_key, 'language');
});

test('published service versions are fetched with selected service key', async () => {
  let selected;
  const result = await view.adapter(() => ({ listContracts: async key => { selected = key; return [{ contract_key: 'vocabulary', version: '1.0.0' }]; } })).contracts({}, 'language');
  assert.equal(selected, 'language');
  assert.equal(result.contracts[0].version, '1.0.0');
});

test('RLS denial is visible, not treated as an empty registry', async () => {
  const result = await view.adapter(() => ({ listContracts: async () => { throw { code: '42501', message: 'permission denied' }; } })).contracts({}, 'language');
  assert.equal(result.status, 'error');
  assert.match(result.message, /RLS/);
});
