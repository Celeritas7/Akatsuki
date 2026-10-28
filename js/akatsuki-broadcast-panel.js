/* akatsuki-broadcast-panel.js — add / list / cancel broadcasts, and switch phone push on.  R054 · Oct 28
 *
 * The hub page's stand-in until Roadmap's own section exists (Roadmap calls the same RPC: akatsuki_broadcast_add).
 *   AkatsukiBroadcastPanel(supabase, { bottom: 84 }).mount();   // a 📣 button, bottom-right; opens a sheet
 * Push needs this page's service worker (sw.js, scope ./) and, on iPhone, the hub installed to the Home Screen.
 */
(function () {
  if (window.AkatsukiBroadcastPanel) return;
  const CSS = `
    :host { all: initial; }
    .fab { position: fixed; right: 16px; z-index: 2147483000; width: 52px; height: 52px; border-radius: 50%; border: 1px solid #3a2d33;
      background: #07050a; color: #fff; font-size: 22px; cursor: pointer; box-shadow: 0 8px 24px rgba(0,0,0,.45); }
    .sheet { position: fixed; inset: 0; z-index: 2147483001; display: flex; align-items: flex-end; justify-content: center; background: rgba(0,0,0,.55);
      font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; color: #efe8e0; }
    .box { width: 100%; max-width: 560px; max-height: 92vh; overflow: auto; box-sizing: border-box; background: #0f0b10; border: 1px solid #2a2127;
      border-radius: 18px 18px 0 0; padding: 18px 16px calc(18px + env(safe-area-inset-bottom)); display: flex; flex-direction: column; gap: 14px; }
    h2 { margin: 0; font-size: 18px; } h3 { margin: 8px 0 0; font-size: 13px; color: #bfb4aa; font-weight: 600; text-transform: uppercase; letter-spacing: .06em; }
    .head { display: flex; align-items: center; gap: 8px; } .head .x { margin-left: auto; }
    label { display: flex; flex-direction: column; gap: 4px; font-size: 13px; color: #bfb4aa; }
    input, textarea { font: inherit; font-size: 16px; color: #efe8e0; background: #1a1418; border: 1px solid #3a2d33; border-radius: 10px; padding: 10px 12px; }
    textarea { min-height: 70px; resize: vertical; }
    button { font: inherit; font-size: 15px; font-weight: 600; min-height: 44px; padding: 0 14px; border-radius: 10px; border: 1px solid #3a2d33;
      background: #1d161b; color: #efe8e0; cursor: pointer; }
    button.primary { background: #c3242b; border-color: #c3242b; color: #fff; }
    button.small { min-height: 34px; font-size: 13px; padding: 0 10px; }
    .item { display: flex; gap: 10px; align-items: flex-start; padding: 10px 0; border-top: 1px solid #221a1f; }
    .item .t { flex: 1; min-width: 0; } .item .t b { display: block; overflow-wrap: anywhere; }
    .muted { color: #9d9188; font-size: 12px; } .msg { min-height: 1em; font-size: 13px; color: #e8a0a0; }
    .ok { color: #9be3a9; } .rowb { display: flex; gap: 8px; flex-wrap: wrap; }`;

  const pad = (n) => String(n).padStart(2, '0');
  const localInput = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
  const fmt = (iso) => new Date(iso).toLocaleString([], { weekday: 'short', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  function b64ToBytes(s) { const p = '='.repeat((4 - (s.length % 4)) % 4); const raw = atob((s + p).replace(/-/g, '+').replace(/_/g, '/')); return Uint8Array.from(raw, c => c.charCodeAt(0)); }

  function AkatsukiBroadcastPanel(supabase, opts = {}) {
    let host = null, root = null, sheet = null;
    const el = (tag, cls, text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };

    async function pushState() {
      if (!('serviceWorker' in navigator) || !('PushManager' in window)) return { can: false, why: 'This browser has no web push. On iPhone, add the hub to the Home Screen and open it from there.' };
      const reg = await navigator.serviceWorker.getRegistration();
      if (!reg) return { can: false, why: 'The hub service worker is not registered yet. Reload the page once.' };
      const sub = await reg.pushManager.getSubscription();
      return { can: true, reg, sub, perm: Notification.permission };
    }
    async function turnOn(msg) {
      msg.textContent = ''; msg.className = 'msg';
      try {
        const st = await pushState(); if (!st.can) throw new Error(st.why);
        if ((await Notification.requestPermission()) !== 'granted') throw new Error('Notifications are blocked for this site. Allow them in the browser settings.');
        const { data: pub, error } = await supabase.rpc('akatsuki_vapid_public'); if (error) throw error;
        if (!pub) throw new Error('The hub has no push key yet. Try again in a minute.');
        const sub = st.sub || await st.reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToBytes(pub) });
        const j = sub.toJSON();
        const device = (navigator.userAgentData && navigator.userAgentData.platform) || (/iPhone|iPad/.test(navigator.userAgent) ? 'iPhone' : /Android/.test(navigator.userAgent) ? 'Android' : 'Desktop');
        const r = await supabase.rpc('akatsuki_push_subscribe', { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth, p_device: device });
        if (r.error) throw r.error;
        msg.className = 'msg ok'; msg.textContent = 'On for this device.'; render();
      } catch (e) { msg.textContent = e.message || String(e); }
    }
    async function test(msg) {
      msg.textContent = ''; msg.className = 'msg';
      const { data, error } = await supabase.functions.invoke('akatsuki-broadcast-push', { body: { test: true } });
      if (error) { let m = error.message; try { m = (await error.context.json()).error || m; } catch { /* keep */ } msg.textContent = m; return; }
      msg.className = 'msg ok'; msg.textContent = `Sent to ${data.delivered} of ${data.devices} device(s).` + (data.errors?.length ? ' ' + data.errors.join('; ') : '');
    }
    async function turnOff(msg) {
      const st = await pushState(); if (!st.can || !st.sub) return;
      const endpoint = st.sub.endpoint; await st.sub.unsubscribe();
      await supabase.from('akatsuki_push_subscriptions').delete().eq('endpoint', endpoint);
      msg.className = 'msg'; msg.textContent = 'Off for this device.'; render();
    }

    async function render() {
      if (!sheet) return;
      const box = sheet.querySelector('.box'); box.replaceChildren();
      const head = el('div', 'head'); head.append(el('h2', null, '📣 Broadcasts'));
      const x = el('button', 'small x', 'Close'); x.onclick = close; head.appendChild(x); box.appendChild(head);
      box.appendChild(el('div', 'muted', 'At its time a broadcast covers every app until you press Done or Snooze, and buzzes the phones switched on below. One-off only.'));

      // add
      const t = el('input'); t.maxLength = 120; t.placeholder = 'What needs doing';
      const b = el('textarea'); b.maxLength = 1000; b.placeholder = 'Details (optional)';
      const w = el('input'); w.type = 'datetime-local';
      const soon = new Date(Date.now() + 3600e3); soon.setMinutes(Math.ceil(soon.getMinutes() / 5) * 5, 0, 0); w.value = localInput(soon);
      const lt = el('label', null, 'Title'); lt.appendChild(t);
      const lb = el('label', null, 'Message'); lb.appendChild(b);
      const lw = el('label', null, 'Due'); lw.appendChild(w);
      const addMsg = el('div', 'msg'); const add = el('button', 'primary', 'Add broadcast');
      add.onclick = async () => {
        addMsg.className = 'msg'; addMsg.textContent = '';
        if (!t.value.trim()) { addMsg.textContent = 'Give it a title.'; return; }
        if (!w.value) { addMsg.textContent = 'Pick a due time.'; return; }
        add.disabled = true;
        const { error } = await supabase.rpc('akatsuki_broadcast_add', { p_title: t.value, p_body: b.value || null, p_due_at: new Date(w.value).toISOString() });
        add.disabled = false;
        if (error) { addMsg.textContent = error.message; return; }
        render();
      };
      box.append(lt, lb, lw, add, addMsg);

      // list
      const { data: list, error } = await supabase.from('akatsuki_broadcasts').select('id,title,body,due_at,show_at,state,snoozes,done_at,done_by,push_note')
        .order('show_at', { ascending: true }).limit(100);
      box.appendChild(el('h3', null, 'Scheduled'));
      if (error) box.appendChild(el('div', 'msg', error.message));
      const sched = (list || []).filter(r => r.state === 'scheduled');
      if (!sched.length) box.appendChild(el('div', 'muted', 'Nothing scheduled.'));
      for (const r of sched) {
        const it = el('div', 'item'); const tx = el('div', 't'); tx.appendChild(el('b', null, r.title));
        tx.appendChild(el('div', 'muted', (r.snoozes ? `snoozed to ${fmt(r.show_at)} · due ${fmt(r.due_at)}` : fmt(r.due_at)) + (r.push_note ? ' · ' + r.push_note : '')));
        const c = el('button', 'small', 'Cancel');
        c.onclick = async () => { if (!confirm(`Cancel "${r.title}"?`)) return; const { error } = await supabase.rpc('akatsuki_broadcast_cancel', { p_id: r.id }); if (error) alert(error.message); render(); };
        it.append(tx, c); box.appendChild(it);
      }
      const past = (list || []).filter(r => r.state !== 'scheduled').sort((a, b) => (b.done_at || b.due_at).localeCompare(a.done_at || a.due_at)).slice(0, 5);
      if (past.length) {
        box.appendChild(el('h3', null, 'Recent'));
        for (const r of past) {
          const it = el('div', 'item'); const tx = el('div', 't'); tx.appendChild(el('b', null, r.title));
          tx.appendChild(el('div', 'muted', r.state === 'done' ? `done ${fmt(r.done_at)} in ${r.done_by || '?'}` : 'cancelled')); it.appendChild(tx); box.appendChild(it);
        }
      }

      // push
      box.appendChild(el('h3', null, 'Phone notifications'));
      const pm = el('div', 'msg'); const rowb = el('div', 'rowb');
      const st = await pushState().catch(e => ({ can: false, why: e.message }));
      const { data: devs } = await supabase.from('akatsuki_push_subscriptions').select('device,last_ok_at,last_error,created_at').order('created_at');
      box.appendChild(el('div', 'muted', (devs || []).length ? 'On for: ' + devs.map(d => d.device || 'device').join(', ') : 'No device is switched on yet.'));
      if (!st.can) box.appendChild(el('div', 'muted', st.why));
      else if (st.sub && st.perm === 'granted') {
        const tb = el('button', 'small', 'Send a test'); tb.onclick = () => test(pm);
        const ob = el('button', 'small', 'Turn off on this device'); ob.onclick = () => turnOff(pm);
        rowb.append(tb, ob);
      } else { const on = el('button', 'primary', 'Turn on for this device'); on.onclick = () => turnOn(pm); rowb.appendChild(on); }
      box.append(rowb, pm);
    }

    function open() {
      if (sheet) return;
      sheet = el('div', 'sheet'); sheet.appendChild(el('div', 'box'));
      sheet.addEventListener('click', (e) => { if (e.target === sheet) close(); });
      root.appendChild(sheet); render();
    }
    function close() { if (sheet) { sheet.remove(); sheet = null; } }

    return {
      mount() {
        if (host) return this;
        host = document.createElement('div'); host.setAttribute('data-akatsuki-broadcast-panel', '');
        root = host.attachShadow({ mode: 'open' });
        const s = document.createElement('style'); s.textContent = CSS; root.appendChild(s);
        const fab = el('button', 'fab', '📣'); fab.title = 'Broadcasts'; fab.setAttribute('aria-label', 'Broadcasts');
        fab.style.bottom = `calc(${opts.bottom ?? 16}px + env(safe-area-inset-bottom, 0px))`;
        fab.onclick = open; root.appendChild(fab);
        document.body.appendChild(host);
        if (location.hash === '#broadcast') open();
        return this;
      },
      unmount() { if (host) host.remove(); host = null; root = null; sheet = null; },
      open, close
    };
  }
  window.AkatsukiBroadcastPanel = AkatsukiBroadcastPanel;
})();
