/* sukkiri-adapter.js — Sukkiri's side of the hub.
 *
 *   <script src="…/js/akatsuki-client.js"></script>
 *   <script src="…/js/adapters/sukkiri-adapter.js"></script>
 *   <script>const skHub = SukkiriHub(supabase);</script>
 *
 * Requires R001 + R002 + R003.
 *
 * This file exists to fix two things the card names:
 *
 * 1. pushCal/pushCalCloud fire on EVERY save with no dirty check. push() below
 *    hashes each item and writes only what actually changed — "publish on real
 *    change only, or two apps ping-pong forever".
 * 2. calendar_app_sukkiri is a whole-payload upsert, so a concurrent Calendar
 *    write is lost. Here each cycle and garbage category is its OWN row in
 *    akatsuki_state, owner_app='sukkiri'. Calendar's away/done/overrides/block
 *    are separate rows it owns; Sukkiri physically cannot overwrite them —
 *    the akatsuki_state guard trigger rejects it.
 */
(function () {
  const APP = 'sukkiri', DOC = 'calapp_sukkiri';
  const h = (s) => { let x = 5381; for (let i = 0; i < s.length; i++) x = ((x << 5) + x + s.charCodeAt(i)) | 0; return (x >>> 0).toString(36); };

  function SukkiriHub(supabase, opts = {}) {
    const hub = window.Akatsuki(supabase, APP, { log: opts.log || (() => {}) });
    const SEEN = 'akatsuki_seen_' + APP;
    const seen = () => { try { return JSON.parse(localStorage.getItem(SEEN) || '{}'); } catch { return {}; } };
    const mark = (o) => localStorage.setItem(SEEN, JSON.stringify(o));

    /** Write one owned item, but only if its content changed. */
    async function push(path, key, value) {
      const s = seen(), k = path + '/' + key, sig = h(JSON.stringify(value));
      if (s[k] === sig) return false;
      await hub.put(DOC, path, key, value);
      s[k] = sig; mark(s); return true;
    }
    async function drop(path, key) {
      const s = seen(), k = path + '/' + key;
      await hub.remove(DOC, path, key);
      delete s[k]; mark(s); return true;
    }
    /** First Phase-B run on a device: learn the rows R009's trigger made for Sukkiri
     *  (cycles keyed from the old payload, garbage as one whole row) so the first
     *  sync removes any that don't match today's keys — no duplicates left behind. */
    async function seed() {
      const s = seen(); if (s.__seeded) return;
      for (const k of await hub.keys(DOC)) if (!(k in s)) s[k] = 'seed';
      s.__seeded = 1; mark(s);
    }

    const api = {
      hub,

      /** Call from save() instead of pushCal/pushCalCloud. Diffs, writes the
       *  changed cycles, and explicitly removes the ones that disappeared —
       *  a delete is no longer just an omission. Returns rows written. */
      async syncCycles(cycles, dueKey, palette) {
        await seed();
        let n = 0;
        const live = new Set();
        for (let i = 0; i < cycles.length; i++) {
          const c = cycles[i], id = 'sk_' + c.id;
          live.add(id);
          const ok = await push('cycles', id, {
            id, name: c.name, every: c.days, kind: 'home',
            anchor: dueKey(c),
            color: c.color || (palette ? palette[(i + 4) % palette.length] : null)
          });
          if (ok) n++;
        }
        for (const k of Object.keys(seen())) {
          if (k.startsWith('cycles/sk_') && !live.has(k.slice(7))) { await drop('cycles', k.slice(7)); n++; }
        }
        return n;
      },

      /** Only publish rules when Sukkiri actually has some — otherwise
       *  Calendar's own rules must stand (the card's condition, preserved). */
      async syncGarbage(garbage) {
        if (!garbage || !garbage.some(g => g.days && g.days.length)) return 0;
        await seed();
        let n = 0;
        const live = new Set();
        for (const g of garbage) {
          live.add(g.id);
          const ok = await push('garbage', g.id, {
            id: g.id, label: g.jp ? g.jp + ' / ' + g.label : g.label,
            short: g.short, icon: g.icon, days: g.days, weeks: g.weeks || [], color: g.color
          });
          if (ok) n++;
        }
        for (const k of Object.keys(seen())) {
          if (k.startsWith('garbage/') && !live.has(k.slice(8))) { await drop('garbage', k.slice(8)); n++; }
        }
        return n;
      },

      /** Replaces pullCalAway(). Reads only paths Calendar owns — a view, no copy.
       *  Returns { away, done, overrides, block, garbage } for calapp_sukkiri. */
      async pullCalendar() {
        const { value, owners } = await hub.doc(DOC);
        const out = {};
        for (const p of ['away', 'done', 'overrides', 'block', 'show', 'wm', 'garbage']) {
          if (owners[p] === 'cal' && value[p] != null) out[p] = value[p];
        }
        return out;
      },

      /** sendToCostApp(). The one genuinely event-shaped write — a real stream
       *  publish, replacing the localStorage array push. */
      async sendPurchaseRequest(req) {
        const payload = { id: req.id, items: req.items, source: 'sukkiri',
                          currency: req.currency || 'JPY', requestedAt: req.requestedAt };
        if (req.totalYen != null) payload.totalYen = req.totalYen;
        if (req.preferred_shop) payload.preferred_shop = req.preferred_shop;   // R015
        if (req.category) payload.category = req.category;                     // R015
        const r = await hub.publish({
          to: 'cost', kind: 'purchase_request',
          addr: { id: req.id }, payload,
          clock: req.requestedAt, key: APP + ':' + req.id
        });
        // R017: Cost already closed this id (rejected | logged). Store nextId as the
        // request's id and send again — never reuse a closed id.
        if (r && r.status === 'closed') {
          const m = /^(.*)-(\d{1,2})$/.exec(req.id);
          r.nextId = m ? m[1] + '-' + (Number(m[2]) + 1) : req.id + '-2';
        }
        return r;
      },

      /** The read path the card says does not exist. Poll for Cost's decision;
       *  onStatus(id, status, expenseIds) is called once per new reply.
       *  R013: cursor is reply_seq, not seq — approved → logged are two replies on
       *  one row, each seen exactly once. onStatus must only set status locally,
       *  never republish (never write what you didn't just read). */
      watchReplies(onStatus, ms = 30000) {
        const CUR = 'akatsuki_replyseq_' + APP;
        const run = async () => {
          const since = Number(localStorage.getItem(CUR) || 0);
          let rows = [];
          try { rows = await hub.replies('purchase_request', since); } catch { return; }
          for (const r of rows || []) {
            if (r.reply && r.reply.status) onStatus(r.reply.id, r.reply.status, r.reply.expense_ids || []);
            localStorage.setItem(CUR, String(r.reply_seq));
          }
        };
        const t = setInterval(run, ms);
        const vis = () => { if (document.visibilityState === 'visible') run(); };
        document.addEventListener('visibilitychange', vis); run();
        return () => { clearInterval(t); document.removeEventListener('visibilitychange', vis); };
      }
    };
    return api;
  }
  window.SukkiriHub = SukkiriHub;
})();

/* ── Where the calls go ───────────────────────────────────────────────────────
 *   save(patch, entry)   → keep the localStorage write. Replace pushCal(st).
 *   queueCloud/cloudPushNow → keep the sukkiri_state upsert (private, own doc).
 *                          Replace pushCalCloud(st) with:
 *                            await skHub.syncCycles(st.cycles, c => dkey(dueAt(c)), CAL_COL);
 *                            await skHub.syncGarbage(st.garbage);
 *   pullCalAway()        → const cal = await skHub.pullCalendar();
 *   sendToCostApp()      → await skHub.sendPurchaseRequest(req);  then DROP the
 *                          localStorage sukkiri_cost_requests array push
 *   initCloud()          → skHub.watchReplies((id, status) => { … });   NEW
 *
 * Do NOT call syncCycles from render, tab switches, or the 2s debounce directly
 * — it is cheap (hash-gated) but the point is that a no-op save writes nothing.
 * calPayload() stays as-is for the localStorage mirror; it is no longer the
 * cloud write path.
 * ─────────────────────────────────────────────────────────────────────────── */
