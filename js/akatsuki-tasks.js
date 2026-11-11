/* Phase 1 shared task contract. Supply the app's authenticated Supabase client. */
(function () {
  function AkatsukiTasks(client, sourceApp) {
    if (!client || !sourceApp) throw new Error('An authenticated client and source app are required');
    return {
      async register({sourceTaskId, title, type = 'other', url = null, taskId = null}) {
        const {data, error} = await client.rpc('akatsuki_task_register', {
          p_source_app: sourceApp, p_source_task_id: String(sourceTaskId), p_title: title,
          p_task_type: type, p_source_url: url, p_task_id: taskId
        });
        if (error) throw error;
        return data;
      },
      async history(taskId, limit = 100) {
        const {data, error} = await client.from('akatsuki_task_events').select('*')
          .eq('task_id', taskId).order('happened_at', {ascending:false}).limit(Math.max(1, Math.min(500, limit)));
        if (error) throw error;
        return data;
      },
      async list() {
        const {data, error} = await client.from('akatsuki_task_status').select('*').eq('source_app', sourceApp);
        if (error) throw error;
        return data;
      },
      async get(sourceTaskId) {
        const {data, error} = await client.from('akatsuki_task_status').select('*')
          .eq('source_app', sourceApp).eq('source_task_id', String(sourceTaskId)).maybeSingle();
        if (error) throw error;
        return data;
      }
    };
  }
  if (typeof module !== 'undefined' && module.exports) module.exports = AkatsukiTasks;
  else window.AkatsukiTasks = AkatsukiTasks;
})();
