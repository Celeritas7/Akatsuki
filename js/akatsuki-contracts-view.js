/* A1C: read-only presentation adapter. Never registers or deploys contracts. */
(function () {
  function classify(error) {
    const message = String(error && error.message || 'Unknown registry error');
    const code = String(error && error.code || '');
    if (code === '42P01' || code === 'PGRST205' || /relation .*akatsuki_contract_|could not find the table .*akatsuki_contract_/i.test(message))
      return { status: 'unavailable', message: 'Contracts registry is not deployed in this database yet. Existing Hub features remain available.' };
    if (code === '42501' || code === 'PGRST301')
      return { status: 'error', message: 'Registry access denied. Check your session and RLS permissions.' };
    return { status: 'error', message: 'Registry could not be loaded: ' + message };
  }
  function adapter(factory) {
    if (typeof factory !== 'function') throw new Error('Registry factory required');
    return {
      async load(client) {
        if (!client) return { status: 'signed-out', apps: [], services: [], contracts: [] };
        try {
          const registry = factory(client);
          const [apps, services] = await Promise.all([registry.listApps(), registry.listServices()]);
          return { status: 'ready', apps, services, contracts: [] };
        } catch (error) { return { ...classify(error), apps: [], services: [], contracts: [] }; }
      },
      async contracts(client, serviceKey) {
        if (!client || !serviceKey) return { status: 'ready', contracts: [] };
        try { return { status: 'ready', contracts: await factory(client).listContracts(serviceKey) }; }
        catch (error) { return { ...classify(error), contracts: [] }; }
      }
    };
  }
  const api = { adapter, classify };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else window.AkatsukiContractsView = api;
})();
