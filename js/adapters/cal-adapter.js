/* cal-adapter.js — Calendar's side of the hub.  v2 · Sep 26
 *
 *   createClient(URL, KEY, { global: { headers: { 'x-akatsuki-app': 'cal' } } })
 *   <script src="…/js/akatsuki-client.js"></script>      (Sep 26 build or later)
 *   <script src="…/js/adapters/cal-adapter.js"></script>
 *   <script>const calHub = CalHub(supabase, { uid: () => UID });</script>
 *
 * The shared doc calapp_sukkiri, as R009's trigger already stores it:
 *   away · done · overrides · block · show · wm  → one row each, whole value   (cal)
 *   cycles                                       → one row per cycle, key sk_<id>
 *                                                  kind=digital (cal) · kind=home (sukkiri)
 *   garbage                                      → Sukkiri's. Calendar never writes it.
 *
 * Enforced here:
 *   1. guest mode never touches the hub.
 *   2. hash gate — a save that changes nothing writes nothing.
 *   3. a deleted digital cycle is an explicit remove, not an omission.
 *   4. nothing read from Sukkiri is written back (applying flag).
 */
(function () {
  const APP = 'cal', DOC = 'calapp_sukkiri';
  const WHOLE = ['away', 'done', 'overrides', 'block', 'show', 'wm'];
  const h = (s) => { let x = 5381; for (let i = 0; i < s.length; i++) x = ((x << 5) + x + s.charCodeAt(i)) | 0; return (x >>> 0).toString(36); };

  function CalHub(supabase, opts = {}) {
    const hub = window.Akatsuki(supabase, APP, { log: opts.log || (() => {}) });
    const uid = opts.uid || (() => null);
    const guest = () => !uid() || uid() === 'guest';
    const SEEN = 'akatsuki_seen_' + APP + '_v2';
    const seen = () => { try { return JSON.parse(localStorage.getItem(SEEN) || '{}'); } catch { return {}; } };
    const mark = (o) => localStorage.setItem(SEEN, JSON.stringify(o));
    let applying = false;

    /** First run on a device: learn which rows Calendar already owns (the trigger
     *  made some), so cycles deleted before today get removed on the first sync. */
    async function seed() {
      const s = seen(); if (s.__seeded) return;
      for (const k of await hub.keys(DOC)) if (!(k in s)) s[k] = 'seed';
      s.__seeded = 1; mark(s);
    }
    async function push(path, key, value) {
      const s = seen(), k = path + '/' + key, sig = h(JSON.stringify(value ?? null));
      if (s[k] === sig) return false;
      await hub.put(DOC, path, key, value ?? null);
      s[k] = sig; mark(s); return true;
    }
    async function drop(path, key) {
      const s = seen();
      await hub.remove(DOC, path, key);
      delete s[path + '/' + key]; mark(s); return true;
    }

    async function pullSukkiri() {
      const { rows } = await hub.doc(DOC);
      const mine = (p) => rows.find(r => r.path === p && r.owner_app === 'sukkiri');
      const c = mine('cycles'), g = mine('garbage');
      return {
        cycles: (c && c.items) || [],
        garbage: g ? (g.items ?? g.scalar ?? null) : null,       // null = Sukkiri has no rules → keep Calendar's own
        seq: Math.max(0, ...rows.filter(r => r.owner_app === 'sukkiri').map(r => Number(r.seq) || 0))
      };
    }

    return {
      hub,
      get applying() { return applying; },

      /** Replaces the calendar_app_sukkiri upsert in saveSukkiri(). Pass the `sk` object. */
      async syncSukkiri(sk) {
        if (guest() || applying) return 0;
        await seed();
        let n = 0;
        for (const p of WHOLE) if (sk[p] !== undefined && await push(p, '', sk[p])) n++;
        const live = new Set();
        for (const c of (sk.cycles || []).filter(c => c.kind === 'digital')) {
          const key = 'sk_' + c.id; live.add(key);
          if (await push('cycles', key, { id: c.id, name: c.name, every: c.every, anchor: c.anchor, color: c.color, kind: 'digital' })) n++;
        }
        for (const k of Object.keys(seen())) {
          if (k.startsWith('cycles/') && !live.has(k.slice(7))) { await drop('cycles', k.slice(7)); n++; }
        }
        return n;
      },

      /** Replaces loadSukkiri()'s read of calendar_app_sukkiri. Sukkiri-owned only:
       *  { cycles: [home cycles], garbage: [rules] | null, seq }. null in guest mode. */
      async pullSukkiri() { return guest() ? null : pullSukkiri(); },

      /** Poll Sukkiri's half; calls onRemote(remote) only when its seq moved.
       *  Runs now, every ms, on focus and on reconnect. Returns stop(). */
      watch(onRemote, ms = opts.pollMs || 20000) {
        let last = -1, busy = false;
        const run = async () => {
          if (guest() || busy) return; busy = true;
          try {
            const r = await pullSukkiri();
            if (r.seq !== last) { applying = true; try { await onRemote(r); } finally { applying = false; } last = r.seq; }
          } catch (e) { (opts.log || (() => {}))('pullSukkiri failed', e.message); }
          finally { busy = false; }
        };
        const vis = () => { if (document.visibilityState === 'visible') run(); };
        window.addEventListener('online', run); document.addEventListener('visibilitychange', vis);
        const t = setInterval(run, ms); run();
        return () => { clearInterval(t); window.removeEventListener('online', run); document.removeEventListener('visibilitychange', vis); };
      },

      /** Day marks — one event per changed date, published from pushDay(). */
      async dayMark(date, d) {
        if (guest()) return { status: 'skipped' };
        const cleared = !d || (!d.marked && !d.isGoal && !d.note);
        try {
          return await hub.publish({
            to: null, kind: 'day.mark', addr: { date },
            payload: cleared ? { date, cleared: true }
              : { date, marked: !!d.marked, markColor: d.markColor || 'red', isGoal: !!d.isGoal, note: d.note || null },
            key: APP + ':' + date
          });
        } catch (e) {
          if (/^AK1\d\d$/.test(e.code || '') || /no route|does not declare/.test(e.message || '')) return { status: 'parked', code: e.code };
          throw e;
        }
      }
    };
  }
  window.CalHub = CalHub;
})();

/* ── Where the calls go (Calendar, js/app.js · sukkiri.js) ────────────────────
 *   loadSukkiri()        → const r = await calHub.pullSukkiri();
 *                          sk.cycles = [...sk.cycles.filter(c => c.kind === 'digital'), ...r.cycles];
 *                          if (r.garbage) sk.garbage = r.garbage;   // else keep Calendar's own
 *                          Remove the select on calendar_app_sukkiri.
 *   init (after auth, after local state loads)
 *                        → calHub.watch(r => { merge as above; render; });
 *   saveSukkiri() (sukkiri.js:86)
 *                        → keep the localStorage write. Replace the calendar_app_sukkiri
 *                          upsert with: await calHub.syncSukkiri(sk);
 *   pushDay(key, data)   → after the upsert/delete succeeds: await calHub.dayMark(key, data);
 *
 * Do NOT call syncSukkiri from the watch callback, render, theme save or
 * saveLocalCal — applying blocks it anyway, but a remote merge is not a change.
 * Calendar never writes garbage: when Sukkiri has no rules, Calendar's stay local.
 * ─────────────────────────────────────────────────────────────────────────── */
