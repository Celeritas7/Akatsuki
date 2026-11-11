/* akatsuki-broadcast.js — due broadcasts cover the screen, in EVERY connected app.  R054 · Oct 28
 *
 * One file, shipped by the hub, never forked.  Needs only the app's own signed-in supabase client:
 *   <script src="https://celeritas7.github.io/Akatsuki/js/akatsuki-broadcast.js"></script>
 *   AkatsukiBroadcast(supabase, 'cost').start();      // this app's id; reads on load, focus, every 60 s
 *
 * What it does
 *   · reads akatsuki_broadcasts (RLS: own rows) that are scheduled and due within the next 6 h
 *   · from show_at on, covers the whole screen until answered — no ✕, no Escape, no click-outside
 *   · Done   → rpc akatsuki_broadcast_done: closed in every app (the row is shared)
 *   · Snooze → rpc akatsuki_broadcast_snooze (10 min · 1 h · 3 h): back everywhere at the new time, and pushed again
 *   · a timer is set for the next one, so an app left open shows it on the minute
 *   · nothing expires: an app that was closed at the due time shows it the next time it opens
 *   · other tabs of the same site hear Done/Snooze at once (BroadcastChannel); other devices on their next read
 *   · signed out → shows nothing (no rows), never errors
 * Actions use owner-checked RPCs, with recurrence created atomically on completion or skip.  Styling is isolated in a shadow root; colours are the hub's.
 */
(function () {
  if (window.AkatsukiBroadcast) return;
  const HORIZON_MS = 6 * 3600e3, POLL_MS = 60e3;
  const SNOOZES = [[10, '10 min'], [60, '1 hour'], [180, '3 hours']];
  const CATEGORIES = { general: 'General', shopping: 'Shopping', cleaning: 'Cleaning', files: 'File Tasks', daily: 'Daily Repetition', expenses: 'Expense Review' };
  const CSS = `
    :host { all: initial; }
    .veil { position: fixed; inset: 0; z-index: 2147483647; display: flex; align-items: center; justify-content: center;
      padding: max(24px, env(safe-area-inset-top)) 20px max(24px, env(safe-area-inset-bottom)); box-sizing: border-box;
      background: radial-gradient(120% 80% at 50% 0%, rgba(195,36,43,.28), rgba(7,5,10,.97) 60%), #07050a;
      color: #efe8e0; font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; overscroll-behavior: contain; }
    .card { max-height: calc(100dvh - 48px); overflow: auto; width: 100%; max-width: 520px; display: flex; flex-direction: column; gap: 18px; }
    .top { display: flex; align-items: center; gap: 10px; color: #bfb4aa; font-size: 13px; letter-spacing: .02em; }
    .moon { font-size: 22px; }
    h1 { margin: 0; font-size: clamp(26px, 7vw, 38px); line-height: 1.15; font-weight: 700; color: #fff; overflow-wrap: anywhere; }
    p { margin: 0; font-size: 17px; line-height: 1.5; color: #e4dad0; white-space: pre-wrap; overflow-wrap: anywhere; max-height: 40vh; overflow: auto; }
    .when { font-size: 13px; color: #bfb4aa; }
    .late { color: #e8a0a0; }
    .row { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 6px; }
    button { font: inherit; font-size: 16px; font-weight: 600; min-height: 48px; padding: 0 18px; border-radius: 12px; border: 1px solid #3a2d33;
      background: #1d161b; color: #efe8e0; cursor: pointer; }
    button:focus-visible { outline: 3px solid #e8a0a0; outline-offset: 2px; }
    button.done { background: #c3242b; border-color: #c3242b; color: #fff; flex: 1 1 100%; font-size: 18px; min-height: 56px; }
    button[disabled] { opacity: .6; cursor: progress; }
    .snz { flex: 1 1 0; }
    .label { width: 100%; font-size: 12px; color: #bfb4aa; margin-top: 4px; }
    .err { min-height: 1em; font-size: 13px; color: #ffb4b4; }
    .task { border-top: 1px solid #493039; padding: 18px 0; }
    h2 { font-size: 20px; margin: 0 0 12px; overflow-wrap: anywhere; }
    input { box-sizing: border-box; max-width: 100%; min-height: 44px; font: inherit; background: #1d161b; color: #fff; border: 1px solid #493039; border-radius: 8px; padding: 8px; }
    .count { margin-left: auto; }`;

  function fmtWhen(iso) {
    const d = new Date(iso);
    return d.toLocaleString([], { weekday: 'short', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  }
  function lateBy(iso) {
    const m = Math.round((Date.now() - Date.parse(iso)) / 60e3);
    if (m < 5) return '';
    if (m < 90) return `${m} min ago`;
    if (m < 48 * 60) return `${Math.round(m / 60)} h ago`;
    return `${Math.round(m / 1440)} days ago`;
  }

  function AkatsukiBroadcast(supabase, app, opts = {}) {
    if (!supabase || !app) throw new Error('AkatsukiBroadcast(supabase, appId)');
    let rows = [], timer = null, nextTimer = null, host = null, root = null, shownId = null, busy = false, bodyOverflow = null;
    const seen = new Set(), receipts = new Set(), receiptPending = new Set();
    const chan = 'BroadcastChannel' in window ? new BroadcastChannel('akatsuki-broadcast') : null;
    if (chan) chan.onmessage = () => read();

    function due() { const now = Date.now(); return rows.filter(r => Date.parse(r.show_at) <= now); }

    function lock(on) {
      const b = document.body; if (!b) return;
      if (on && bodyOverflow === null) { bodyOverflow = b.style.overflow; b.style.overflow = 'hidden'; }
      if (!on && bodyOverflow !== null) { b.style.overflow = bodyOverflow; bodyOverflow = null; }
    }
    function mount() {
      if (host) return;
      host = document.createElement('div');
      host.setAttribute('data-akatsuki-broadcast', '');
      root = host.attachShadow({ mode: 'open' });
      const style = document.createElement('style'); style.textContent = CSS; root.appendChild(style);
      document.body.appendChild(host);
    }
    function unmount() { if (host) { host.remove(); host = null; root = null; } shownId = null; lock(false); }

    function el(tag, cls, text) { const n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; }

    function recordShown(list) {
      if (document.visibilityState === 'hidden') return;
      for (const b of list) {
        const key = b.id + ':' + b.show_at;
        if (receipts.has(key) || receiptPending.has(key)) continue;
        receiptPending.add(key);
        Promise.resolve().then(() => supabase.rpc('akatsuki_broadcast_shown', {p_id:b.id,p_show_at:b.show_at,p_app:app}))
          .then(r => { if (!r.error) receipts.add(key); })
          .catch(() => {}).finally(() => receiptPending.delete(key));
      }
    }

    function render() {
      const list = due();
      if (!list.length) { unmount(); return; }
      recordShown(list);
      const signature = JSON.stringify(list);
      if (host && shownId === signature) return;           // already showing this one
      mount(); lock(true);
      [...root.childNodes].forEach(n => { if (n.tagName !== 'STYLE') n.remove(); });
      const veil = el('div', 'veil');
      veil.setAttribute('role', 'alertdialog'); veil.setAttribute('aria-modal', 'true'); veil.setAttribute('aria-labelledby', 'akb-title');
      const card = el('div', 'card');
      const top = el('div', 'top');
      top.append(el('span', 'moon', '🌑'), el('span', null, 'Akatsuki broadcast'));
      top.appendChild(el('span', 'count', `${list.length} pending`));
      const heading = el('h1', null, 'Due broadcasts'); heading.id = 'akb-title';
      card.append(top, heading);
      for (const [category, label] of Object.entries(CATEGORIES)) {
        const items = list.filter(b => (b.category || 'general') === category);
        if (!items.length) continue;
        card.appendChild(el('h2', null, `${label} · ${items.length}`));
        for (const b of items) {
          const task = el('section', 'task'); task.appendChild(el('h2', null, b.title));
          if (b.body) task.appendChild(el('p', null, b.body));
          task.appendChild(el('div', 'when', 'Due ' + fmtWhen(b.due_at) + (b.repeat_days ? ` · every ${b.repeat_days} day(s)` : '')));
          const err = el('div', 'err'); err.setAttribute('role', 'status');
          const row = el('div', 'row');
          const done = el('button', 'done', 'Done');
          done.onclick = () => act(b, () => supabase.rpc('akatsuki_broadcast_done', { p_id: b.id, p_app: app }), err, row);
          row.appendChild(done);
          const defaultSnooze = el('button', 'snz', 'Snooze');
          defaultSnooze.title = 'Use your saved default snooze duration';
          defaultSnooze.onclick = () => act(b, () => supabase.rpc('akatsuki_broadcast_snooze_default', {p_id:b.id,p_expected_show_at:b.show_at,p_app:app}), err, row);
          row.appendChild(defaultSnooze);
          for (const [m, label] of SNOOZES) {
            const snooze = el('button', 'snz', label);
            snooze.onclick = () => act(b, () => supabase.rpc('akatsuki_broadcast_snooze', { p_id: b.id, p_minutes: m }), err, row);
            row.appendChild(snooze);
          }
          const atLabel = el('label', 'label', 'Remind me at');
          const at = el('input'); at.type = 'datetime-local'; atLabel.appendChild(at);
          const schedule = el('button', null, 'Schedule for…');
          schedule.onclick = () => {
            const date = new Date(at.value);
            if (!at.value || !Number.isFinite(date.getTime()) || date <= new Date()) { err.textContent = 'Choose a future time.'; return; }
            act(b, () => supabase.rpc('akatsuki_broadcast_reschedule', { p_id: b.id, p_at: date.toISOString() }), err, row);
          };
          const skipChoice = el('button', null, 'Skip…');
          const choices = el('div', 'row'); choices.style.display = 'none';
          choices.appendChild(el('span', 'label', 'Do this later, or skip this occurrence?'));
          const later = el('button', null, 'Do later');
          later.onclick = () => act(b, () => supabase.rpc('akatsuki_broadcast_snooze_default', {p_id:b.id,p_expected_show_at:b.show_at,p_app:app}), err, row);
          const skip = el('button', null, 'Skip this occurrence');
          skip.onclick = () => act(b, () => supabase.rpc('akatsuki_broadcast_skip', { p_id: b.id, p_app: app }), err, row);
          const back = el('button', null, 'Back'); back.onclick = () => { choices.style.display = 'none'; };
          choices.append(later, skip, back);
          skipChoice.onclick = () => { choices.style.display = ''; };
          row.append(atLabel, schedule, skipChoice, choices); task.append(row, err); card.appendChild(task);
        }
      }
      veil.appendChild(card);
      // Blocking: keep focus inside, swallow Escape.
      veil.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); }
        if (e.key === 'Tab') {
          const f = [...root.querySelectorAll('button:not([disabled]), input:not([disabled])')]; if (!f.length) return;
          const i = f.indexOf(root.activeElement);
          if (e.shiftKey && i <= 0) { e.preventDefault(); f[f.length - 1].focus(); }
          else if (!e.shiftKey && i === f.length - 1) { e.preventDefault(); f[0].focus(); }
        }
      });
      root.appendChild(veil);
      shownId = signature;
      setTimeout(() => root?.querySelector('button')?.focus(), 30);
      for (const b of list) {
        if (!seen.has(b.id + b.show_at)) { seen.add(b.id + b.show_at); try { navigator.vibrate?.([200, 100, 200]); } catch { /* requires interaction */ } }
      }
    }

    async function act(b, call, err, row) {
      if (busy) return;
      busy = true; ++readVersion; err.textContent = ''; row.querySelectorAll('button').forEach(x => (x.disabled = true));
      try {
        const { error } = await call();
        if (error) throw error;
        rows = rows.filter(r => r.id !== b.id);
        if (chan) chan.postMessage({ id: b.id });
        busy = false; render(); read();
      } catch (e) {
        busy = false;
        row.querySelectorAll('button').forEach(x => (x.disabled = false));
        err.textContent = (navigator.onLine === false ? 'Offline — ' : 'Could not save — ') + (e.message || e) + '. Try again.';
      }
    }

    function arm() {
      clearTimeout(nextTimer); nextTimer = null;
      const now = Date.now();
      const next = rows.map(r => Date.parse(r.show_at)).filter(t => t > now).sort((a, b) => a - b)[0];
      if (next) nextTimer = setTimeout(() => render(), Math.min(next - now + 500, 2 ** 31 - 1));
    }

    let readVersion = 0;
    async function read() {
      if (busy) return;
      const version = ++readVersion;
      try {
        const { data, error } = await supabase.from('akatsuki_broadcasts')
          .select('id,title,body,due_at,show_at,snoozes,created_by,category,repeat_days')
          .eq('state', 'scheduled').lte('show_at', new Date(Date.now() + HORIZON_MS).toISOString())
          .order('show_at').limit(50);
        if (error) throw error;
        if (busy || version !== readVersion) return;
        rows = data || [];
      } catch (e) { if (opts.log !== false) console.warn('[ak broadcast] read failed', e.message || e); return; }
      if (!busy) render();
      arm();
    }

    let stops = [];
    return {
      start(ms = POLL_MS) {
        if (stops.length) return () => this.stop();
        read(); timer = setInterval(read, ms);
        const onVis = () => { if (document.visibilityState === 'visible') read(); };
        document.addEventListener('visibilitychange', onVis);
        window.addEventListener('online', read);
        window.addEventListener('focus', read);
        stops = [() => clearInterval(timer), () => clearTimeout(nextTimer), () => document.removeEventListener('visibilitychange', onVis),
                 () => window.removeEventListener('online', read), () => window.removeEventListener('focus', read), unmount];
        return () => this.stop();
      },
      stop() { stops.forEach(f => f()); stops = []; },
      refresh: read,
      due: () => due().slice()
    };
  }
  window.AkatsukiBroadcast = AkatsukiBroadcast;
})();
