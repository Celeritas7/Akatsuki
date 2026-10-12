/* jlpt-adapter.js — Japanese Study's side of the hub.  R020 · Sep 26
 *
 * DUAL SESSION.  This app's own project (ulgrfumbwjovbjzjiems, window.sb) is untouched.
 * The hub gets a SECOND client, signed in to wylxvmkcrexwfpjpbhyy with the same
 * Google account.  Rules that keep the two from colliding:
 *   · the hub client is never window.sb
 *   · storageKey 'akatsuki_hub_auth' — its own slot in localStorage
 *   · detectSessionInUrl: false — an OAuth redirect on a page is ALWAYS the own project's
 *   · sign-in to the hub happens only on hub-login.html, which has only the hub client
 *
 *   <script src="js/akatsuki-client.js"></script>
 *   <script src="js/jlpt-adapter.js"></script>
 *   <script src="js/hub-config.js"></script>   (sets window.AK_HUB_ANON)
 *   const jlptHub = JlptHub(window.supabase, { uid: () => app.isGuestMode ? null : app.user?.id, log });
 *   (window.supabase = the CDN namespace, not window.sb)
 */
(function () {
  const APP = 'jlpt', HUB_URL = 'https://wylxvmkcrexwfpjpbhyy.supabase.co', STORE = 'akatsuki_hub_auth';
  const GUEST = 'd469efb7-f9e1-4b49-8b14-75a42b4d22e0';

  function hubClient(ns, anonKey) {
    return ns.createClient(HUB_URL, anonKey, {
      auth: { storageKey: STORE, persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
      global: { headers: { 'x-akatsuki-app': APP } }
    });
  }

  function JlptHub(ns, opts = {}) {
    const log = opts.log || (() => {});
    const uid = opts.uid || (() => null);
    const guest = () => !uid() || uid() === GUEST || uid() === 'guest';
    const client = hubClient(ns, opts.hubAnonKey || window.AK_HUB_ANON);
    const hub = window.Akatsuki(client, APP, { log });

    async function session() { const { data } = await client.auth.getSession(); return data.session || null; }

    return {
      hub, client,
      /** true when the hub session exists. Not the same as the own-project session. */
      async signedIn() { return !!(await session()); },
      /** Opens hub-login.html (popup). Resolves when the session lands in localStorage.
       *  Call it DIRECTLY from a click handler — window.open runs before any await, so
       *  the popup blocker allows it. Never from init or an await chain. */
      login() {
        if (guest()) return Promise.resolve(false);
        const w = window.open('hub-login.html', 'akatsuki_hub_login', 'width=480,height=640');
        return new Promise((res) => {
          const t = setInterval(async () => {
            if (await session()) { clearInterval(t); try { w && w.close(); } catch {} res(true); }
            else if (w && w.closed) { clearInterval(t); res(false); }
          }, 800);
        });
      },
      async logout() { await client.auth.signOut(); },

      /** Replaces rmComplete(). Publishes session.completed AND (for now) calls Roadmap's
       *  RPC through the hub client — with the user's JWT, never the bare anon key.
       *  Same identity as today: (task_id, day_key). Returns { published, rpc }. */
      async sessionCompleted(h, { duration, mode, words, level, correct, testType } = {}) {
        if (guest() || !h || !h.task) return { skipped: 'guest or no rm_task' };
        if (!(await session())) { log('hub not signed in — session.completed not sent'); return { skipped: 'no hub session', needsLogin: true }; }
        const payload = { task_id: h.task, day_key: h.day, duration: Math.max(1, Math.round(duration || 1)), mode, source: 'japanese-study-app-advanced' };
        if (words != null) payload.words = words;
        if (level != null) payload.level = level;
        if (correct != null) payload.correct = correct;
        if (testType) payload.test_type = testType;
        const out = {};
        try {
          out.published = await hub.publish({ to: 'rm', kind: 'session.completed', addr: { task_id: h.task, day_key: h.day },
            payload, key: `${APP}:session:${h.task}:${h.day}` });
        } catch (e) { out.published = { status: 'error', code: e.code, message: e.message }; log('publish failed', e.code, e.message); }
        // Transitional: Roadmap has no consumer yet. Delete this block when the route is live.
        const feedback = { words, mode, level, correct, testType };
        const { error } = await client.rpc('roadmap_complete_session', {
          p_task_id: h.task, p_source: 'japanese-study-app-advanced', p_day_key: h.day,
          p_duration: payload.duration, p_feedback: feedback, p_verification: 'app' });
        out.rpc = error ? { ok: false, message: error.message } : { ok: true };
        return out;
      }
    };
  }
  window.JlptHub = JlptHub;
  window.JlptHub.client = hubClient;
})();

/* ── Where the calls go (confirmed against the repo, Sep 27) ────────────────────
 *   index.html, before the app.js module:
 *       <script src="js/hub-config.js"></script>
 *       <script src="js/akatsuki-client.js"></script>
 *       <script src="js/jlpt-adapter.js"></script>
 *   rmSession.js: RM_KEY → window.AK_HUB_ANON (delete the literal). Handshake stays.
 *   app.js init(), after the own session:
 *       window.jlptHub = JlptHub(window.supabase, { uid: () => this.isGuestMode ? null : this.user?.id });
 *       if (rmIsLaunched() && !this.isGuestMode && !(await jlptHub.signedIn())) showHubSignIn();
 *   showHubSignIn(): a small bar "Sign in to Akatsuki so this session reaches Roadmap" with a
 *       button whose onclick is () => jlptHub.login().then(ok => ok && hideHubSignIn()).
 *       Never auto-open the popup.
 *   rmComplete({ durationMin, feedback, taskId }) keeps its signature and both call sites.
 *       Inside: const r = await window.jlptHub.sessionCompleted(hs, { duration: mins, ...feedback });
 *       if (r.needsLogin) { stash {hs, mins, feedback} in sessionStorage 'rm-pending'; showHubSignIn(); }
 *       After login() resolves true, send 'rm-pending' once and clear it.
 *       return !!(r.rpc && r.rpc.ok) || ['pending','skipped'].includes(r.published && r.published.status);
 * ─────────────────────────────────────────────────────────────────────────── */
