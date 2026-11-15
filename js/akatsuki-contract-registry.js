/* A1B: metadata registration/discovery. Pass the authenticated Akatsuki-project Supabase client.
   This is not service authorization, contract approval, or a vocabulary API client. */
(function () {
  function Registry(client) {
    if (!client || typeof client.rpc !== 'function' || typeof client.from !== 'function')
      throw new Error('Authenticated Supabase client required');

    async function query(table, configure) {
      const request = configure(client.from(table).select('*'));
      const {data,error} = await request;
      if (error) throw error;
      return data;
    }

    async function register(kind, metadata) {
      if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata))
        throw new Error('Registration metadata must be an object');
      const {data,error} = await client.rpc('akatsuki_contract_register', {
        p_kind:kind,p_metadata:metadata
      });
      if (error) throw error;
      return data;
    }

    return Object.freeze({
      registerApp: metadata => register('app',metadata),
      registerService: metadata => register('service',metadata),
      listApps: () => query('akatsuki_contract_apps',q => q.order('app_key')),
      listServices: () => query('akatsuki_contract_services',q => q.order('service_key')),
      // Only published/deprecated versions are discoverable by consumers.
      listContracts: serviceKey => {
        if (typeof serviceKey !== 'string' || !/^[a-z0-9][a-z0-9_-]{1,63}$/.test(serviceKey))
          throw new Error('Valid service key required');
        return query('akatsuki_contract_versions',q => q.eq('service_key',serviceKey)
          .in('lifecycle',['published','deprecated']).order('contract_key').order('version'));
      }
    });
  }
  if (typeof module !== 'undefined' && module.exports) module.exports = Registry;
  else window.AkatsukiContractRegistry = Registry;
})();
