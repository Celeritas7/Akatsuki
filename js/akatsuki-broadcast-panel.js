/* akatsuki-broadcast-panel.js — add / list / cancel broadcasts, and switch phone push on.  R054 · Oct 28
 *   R062 · Nov 4: "When I arrive" — a rule fires a broadcast on arrival at a saved place (Home, Office…),
 *   on the first arrival of each day or on the next arrival only.
 *   R062b · Nov 4: places are grouped into country hubs (from their coordinates); the picker shows the chosen
 *   hub only.  The choice is remembered on this device.  Rules in every hub stay active.
 *   R063 · Nov 4: each hub lists "My places" and "Areas" (akatsuki_areas — Cost's areas, by their country).
 *
 * The hub page's stand-in until Roadmap's own section exists (Roadmap calls the same RPC: akatsuki_broadcast_add).
 *   AkatsukiBroadcastPanel(supabase, { bottom: 84, app: 'akatsuki' }).mount();   // a 📣 button, bottom-right; opens a sheet
 *   app: recorded as the broadcast's created_by (R058); defaults to 'akatsuki'.
 * Push needs this page's service worker (sw.js, scope ./) and, on iPhone, the hub installed to the Home Screen.
 */
(function () {
  if (window.AkatsukiBroadcastPanel) return;
  const CATEGORIES = { general: 'General', shopping: 'Shopping', cleaning: 'Cleaning', files: 'File Tasks', daily: 'Daily Repetition', expenses: 'Expense Review' };
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
    input, textarea, select { font: inherit; font-size: 16px; color: #efe8e0; background: #1a1418; border: 1px solid #3a2d33; border-radius: 10px; padding: 10px 12px; }
    textarea { min-height: 70px; resize: vertical; }
    button { font: inherit; font-size: 15px; font-weight: 600; min-height: 44px; padding: 0 14px; border-radius: 10px; border: 1px solid #3a2d33;
      background: #1d161b; color: #efe8e0; cursor: pointer; }
    button.primary { background: #c3242b; border-color: #c3242b; color: #fff; }
    button.small { min-height: 34px; font-size: 13px; padding: 0 10px; }
    .item { display: flex; gap: 10px; align-items: flex-start; padding: 10px 0; border-top: 1px solid #221a1f; }
    .item .t { flex: 1; min-width: 0; } .item .t b { display: block; overflow-wrap: anywhere; }
    .muted { color: #9d9188; font-size: 12px; } .msg { min-height: 1em; font-size: 13px; color: #e8a0a0; }
    .ok { color: #9be3a9; } .rowb { display: flex; gap: 8px; flex-wrap: wrap; }
    .folders { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
    .folder { position: relative; min-height: 64px; display: flex; flex-direction: column; align-items: flex-start; justify-content: center; gap: 3px; text-align: left; }
    .folder::before { content: ''; position: absolute; top: -5px; left: 10px; width: 30px; height: 6px; border: 1px solid #3a2d33; border-bottom: 0; border-radius: 5px 5px 0 0; background: #1d161b; }
    .folder[aria-pressed='true'] { background: #c3242b; border-color: #e64a50; color: #fff; }
    .folder[aria-pressed='true']::before { background: #c3242b; border-color: #e64a50; }
    .folder span { font-size: 12px; font-weight: 400; color: #bfb4aa; }
    .folder[aria-pressed='true'] span { color: #fff; }
    details.task-folder { border: 1px solid #2a2127; border-radius: 12px; overflow: hidden; background: #120e12; }
    details.task-folder > summary { cursor: pointer; list-style: none; min-height: 48px; padding: 0 12px; display: flex; align-items: center; justify-content: space-between; gap: 8px; font-weight: 700; }
    details.task-folder > summary::-webkit-details-marker { display: none; }
    details.task-folder > summary::after { content: '+'; color: #bfb4aa; font-size: 20px; }
    details.task-folder[open] > summary::after { content: '−'; }
    .folder-items { padding: 0 12px 8px; }
    @media (min-width: 480px) { .folders { grid-template-columns: repeat(3, minmax(0, 1fr)); } }`;

  const pad = (n) => String(n).padStart(2, '0');
  const localInput = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
  const fmt = (iso) => new Date(iso).toLocaleString([], { weekday: 'short', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  // Country hubs, worked out from a place's coordinates (country-sized boxes; HK is checked before the wider ones).
  const HUBS = [
    { id: 'jp', label: '🇯🇵 Japan', box: [24, 46, 122, 154] },
    { id: 'in', label: '🇮🇳 India', box: [6, 37, 68, 98] },
    { id: 'hk', label: '🇭🇰 Hong Kong', box: [22.1, 22.6, 113.8, 114.5] },
  ];
  const hubOf = (p) => { const inBox = (h) => p.lat >= h.box[0] && p.lat <= h.box[1] && p.lng >= h.box[2] && p.lng <= h.box[3];
    const hk = HUBS[2]; if (inBox(hk)) return 'hk'; const h = HUBS.find(inBox); return h ? h.id : 'other'; };
  const HUB_KEY = 'akatsuki.broadcast.hub';
  const hubGet = () => { try { return localStorage.getItem(HUB_KEY); } catch { return null; } };
  const hubSet = (v) => { try { localStorage.setItem(HUB_KEY, v); } catch { /* private mode: not remembered */ } };
  function b64ToBytes(s) { const p = '='.repeat((4 - (s.length % 4)) % 4); const raw = atob((s + p).replace(/-/g, '+').replace(/_/g, '/')); return Uint8Array.from(raw, c => c.charCodeAt(0)); }

  function AkatsukiBroadcastPanel(supabase, opts = {}) {
    const app = opts.app || 'akatsuki';
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
      box.appendChild(el('div', 'muted', 'At its time — or when you arrive at a place — a broadcast appears in every connected app until completed, skipped, or postponed, and buzzes the phones switched on below.'));

      // One request key survives retries until this form is successfully submitted.
      const requestId = crypto.randomUUID();
      const category = el('input'); category.type = 'hidden'; category.value = 'general';
      const lc = el('fieldset'); lc.style.cssText = 'border:0;padding:0;margin:0;display:flex;flex-direction:column;gap:10px';
      const categoryLegend = el('legend', null, 'Choose a task folder'); categoryLegend.style.cssText = 'padding:0 0 10px;font-size:13px;color:#bfb4aa'; lc.appendChild(categoryLegend);
      const folders = el('div', 'folders');
      for (const [value, label] of Object.entries(CATEGORIES)) {
        const folder = el('button', 'folder'); folder.type = 'button'; folder.dataset.category = value;
        folder.setAttribute('aria-pressed', String(value === category.value));
        folder.append(document.createTextNode(label), el('span', null, 'Add tasks here'));
        folder.onclick = () => {
          category.value = value;
          folders.querySelectorAll('.folder').forEach(button => button.setAttribute('aria-pressed', String(button === folder)));
        };
        folders.appendChild(folder);
      }
      lc.append(folders, category);
      const repeat = el('select');
      for (const [value, label] of [['0','Once'],['1','Daily'],['7','Weekly'],['custom','Custom interval']]) { const o = el('option', null, label); o.value = value; repeat.appendChild(o); }
      const lr = el('label', null, 'Repeat'); lr.appendChild(repeat);
      const days = el('input'); days.type = 'number'; days.min = '1'; days.max = '3650'; days.step = '1'; days.value = '14';
      const ld = el('label', null, 'Every how many days?'); ld.appendChild(days); ld.hidden = true;
      repeat.onchange = () => { ld.hidden = repeat.value !== 'custom'; };
      const zone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'Asia/Tokyo';
      const recurrenceHint = el('div', 'muted', `Uses ${zone}. Unfinished items stay pending. After Done or Skip, the next future scheduled day is used.`);
      // add
      const t = el('input'); t.maxLength = 120; t.placeholder = 'What needs doing';
      const b = el('textarea'); b.maxLength = 1000; b.placeholder = 'Details (optional)';
      const w = el('input'); w.type = 'datetime-local';
      const soon = new Date(Date.now() + 3600e3); soon.setMinutes(Math.ceil(soon.getMinutes() / 5) * 5, 0, 0); w.value = localInput(soon);
      const lt = el('label', null, 'Title'); lt.appendChild(t);
      const lb = el('label', null, 'Message'); lb.appendChild(b);
      const lw = el('label', null, 'Due'); lw.appendChild(w);
      // R062: when = a time, or arrival at a saved place
      const when = el('select'); [['time', 'At a time'], ['arrive', 'When I arrive at a place']].forEach(([v, l]) => { const o = el('option', null, l); o.value = v; when.appendChild(o); });
      const lwhen = el('label', null, 'When'); lwhen.appendChild(when);
      const pl = el('select'), md = el('select');
      [['daily_first', 'First arrival of each day'], ['once', 'Next arrival only']].forEach(([v, l]) => { const o = el('option', null, l); o.value = v; md.appendChild(o); });
      const { data: places } = await supabase.from('akatsuki_places').select('id,label,lat,lng,retired_at').is('retired_at', null).not('lat', 'is', null).order('ord', { nullsFirst: false });
      (places || []).forEach(p => { p.hub = hubOf(p); p.key = 'p:' + p.id; });
      const { data: areaRows } = await supabase.from('akatsuki_areas').select('id,label,country,lat,lng,retired_at').is('retired_at', null).not('lat', 'is', null).order('label');
      const areas = (areaRows || []).map(a => ({ ...a, key: 'a:' + a.id, hub: ({ JP: 'jp', IN: 'in', HK: 'hk' })[String(a.country || '').toUpperCase()] || hubOf(a) }));
      // hub switch: only hubs that have places; remembered on this device; Japan first by default
      const targets = [...(places || []), ...areas];
      const hubs = HUBS.filter(h => targets.some(p => p.hub === h.id));
      if (targets.some(p => p.hub === 'other')) hubs.push({ id: 'other', label: '🌐 Other' });
      const hb = el('select'); hubs.forEach(h => { const o = el('option', null, h.label); o.value = h.id; hb.appendChild(o); });
      const saved = hubGet(); hb.value = hubs.some(h => h.id === saved) ? saved : (hubs[0] ? hubs[0].id : '');
      const fillPlaces = () => {
        pl.replaceChildren();
        for (const [name, list] of [['My places', places || []], ['Areas', areas]]) {
          const mine = list.filter(p => p.hub === hb.value); if (!mine.length) continue;
          const g = el('optgroup'); g.label = name;
          mine.forEach(p => { const o = el('option', null, p.label); o.value = p.key; g.appendChild(o); });
          pl.appendChild(g);
        }
        if ([...pl.options].some(o => o.value === 'p:home')) pl.value = 'p:home';
      };
      hb.addEventListener('change', () => { hubSet(hb.value); fillPlaces(); });
      fillPlaces();
      const lhb = el('label', null, 'Hub'); lhb.appendChild(hb);
      const lpl = el('label', null, 'Place'); lpl.appendChild(pl);
      const lmd = el('label', null, 'Repeat'); lmd.appendChild(md);
      const showWhen = () => { const a = when.value === 'arrive'; lw.style.display = lr.style.display = recurrenceHint.style.display = a ? 'none' : ''; ld.hidden = a || repeat.value !== 'custom'; lc.style.display = a ? 'none' : ''; lhb.style.display = lpl.style.display = lmd.style.display = a ? '' : 'none'; };
      when.addEventListener('change', showWhen);
      // Say the picked time back in words: a picker left on today's date with an after-midnight time is easy to miss.
      const hint = el('div', 'muted');
      const sayWhen = () => {
        if (!w.value) { hint.textContent = ''; return; }
        const ms = new Date(w.value).getTime() - Date.now(), min = Math.round(ms / 60e3);
        const rel = ms < -60e3 ? 'in the past' : min <= 1 ? 'in about a minute' : min < 90 ? `in ${min} min` : min < 48 * 60 ? `in ${Math.round(min / 60)} h` : `in ${Math.round(min / 1440)} days`;
        hint.textContent = `${fmt(new Date(w.value).toISOString())} — ${rel}`;
        hint.style.color = ms < -60e3 ? '#ffb4b4' : '';
      };
      w.addEventListener('input', sayWhen); sayWhen(); lw.appendChild(hint);
      const addMsg = el('div', 'msg'); const add = el('button', 'primary', 'Add broadcast');
      add.onclick = async () => {
        addMsg.className = 'msg'; addMsg.textContent = '';
        if (!t.value.trim()) { addMsg.textContent = 'Give it a title.'; return; }
        if (when.value === 'arrive') {
          if (!pl.value) { addMsg.textContent = 'Pick a place.'; return; }
          add.disabled = true;
          const isArea = pl.value.startsWith('a:'), id = pl.value.slice(2);
          const r = await supabase.rpc('akatsuki_broadcast_rule_add', { p_place_id: isArea ? null : id, p_area_id: isArea ? id : null, p_title: t.value, p_body: b.value || null, p_mode: md.value, p_app: app });
          add.disabled = false;
          if (r.error) { addMsg.textContent = r.error.message; return; }
          render(); return;
        }
        if (!w.value) { addMsg.textContent = 'Pick a due time.'; return; }
        if (new Date(w.value).getTime() < Date.now() - 60e3) { addMsg.textContent = 'That time has already passed — check the date.'; return; }
        add.disabled = true;
        const interval = Number(repeat.value === 'custom' ? days.value : repeat.value);
        if (!Number.isInteger(interval) || interval < (repeat.value === 'custom' ? 1 : 0) || interval > 3650) { add.disabled = false; addMsg.textContent = 'Choose an interval of 1–3650 days.'; return; }
        let error;
        try {
          ({ error } = await supabase.rpc('akatsuki_broadcast_create', { p_title: t.value, p_body: b.value || null, p_due_at: new Date(w.value).toISOString(), p_app: app, p_category: category.value, p_repeat_days: interval, p_timezone: zone, p_request_id: requestId }));
        } catch (e) { error = e; }
        add.disabled = false;
        if (error) { addMsg.textContent = error.message; return; }
        render();
      };
      box.append(lt, lb, lc, lwhen, lw, lr, ld, recurrenceHint, lhb, lpl, lmd, add, addMsg); showWhen();

      // R062: arrival rules
      const { data: rules } = await supabase.from('akatsuki_broadcast_rules').select('id,place_id,area_id,title,mode,state,last_fired_at,fired_count')
        .eq('state', 'active').order('created_at');
      if ((rules || []).length) {
        const label = (r) => { const p = r.area_id ? areas.find(q => q.id === r.area_id) : (places || []).find(q => q.id === r.place_id);
          if (!p) return r.place_id || 'area'; const h = HUBS.find(x => x.id === p.hub); return (h ? h.label.split(' ')[0] + ' ' : '') + p.label + (r.area_id ? ' (area)' : ''); };
        box.appendChild(el('h3', null, 'When I arrive'));
        for (const r of rules) {
          const it = el('div', 'item'); const tx = el('div', 't'); tx.appendChild(el('b', null, r.title));
          tx.appendChild(el('div', 'muted', `${label(r)} · ${r.mode === 'once' ? 'next arrival only' : 'first arrival each day'}` + (r.last_fired_at ? ` · last ${fmt(r.last_fired_at)}` : ' · not fired yet')));
          const c = el('button', 'small', 'Cancel');
          c.onclick = async () => { if (!confirm(`Stop "${r.title}"?`)) return; const { error } = await supabase.rpc('akatsuki_broadcast_rule_cancel', { p_id: r.id }); if (error) alert(error.message); render(); };
          it.append(tx, c); box.appendChild(it);
        }
      }

      // list
      const { data: list, error } = await supabase.from('akatsuki_broadcasts').select('id,title,body,due_at,show_at,state,snoozes,done_at,done_by,push_note,category,repeat_days')
        .eq('state', 'scheduled').order('show_at', { ascending: true });
      box.appendChild(el('h3', null, 'Task folders'));
      if (error) box.appendChild(el('div', 'msg', error.message));
      const sched = (list || []).filter(r => r.state === 'scheduled');
      for (const [category, label] of Object.entries(CATEGORIES)) {
        const grouped = sched.filter(r => (r.category || 'general') === category);
        const folder = el('details', 'task-folder');
        const summary = el('summary'); summary.append(el('span', null, label), el('span', 'muted', `${grouped.length} remaining`)); folder.appendChild(summary);
        const items = el('div', 'folder-items');
        if (!grouped.length) items.appendChild(el('div', 'muted', 'No remaining tasks in this folder.'));
        for (const r of grouped) {
          const it = el('div', 'item'); const tx = el('div', 't'); tx.appendChild(el('b', null, r.title));
          tx.appendChild(el('div', 'muted', (r.snoozes ? `snoozed to ${fmt(r.show_at)} · due ${fmt(r.due_at)}` : fmt(r.due_at)) + (r.push_note ? ' · ' + r.push_note : '')));
          const c = el('button', 'small', r.repeat_days ? 'Stop repeating' : 'Cancel');
          c.onclick = async () => { if (!confirm(`Cancel "${r.title}"?`)) return; const { error } = await supabase.rpc('akatsuki_broadcast_cancel', { p_id: r.id }); if (error) alert(error.message); render(); };
          tx.appendChild(el('div', 'muted', (Date.parse(r.show_at) <= Date.now() ? 'Pending' : 'Scheduled') + (r.repeat_days ? ` · every ${r.repeat_days} day(s)` : ' · once')));
          const change = el('select'); change.setAttribute('aria-label', `Move ${r.title} to folder`);
          for (const [value, folderLabel] of Object.entries(CATEGORIES)) { const o = el('option', null, folderLabel); o.value = value; change.appendChild(o); }
          change.value = r.category || 'general';
          change.onchange = async () => { change.disabled = true; const {error} = await supabase.rpc('akatsuki_broadcast_category', {p_id:r.id,p_category:change.value}); if(error) alert(error.message); render(); };
          tx.appendChild(change);
          it.append(tx, c); items.appendChild(it);
        }
        folder.appendChild(items); box.appendChild(folder);
      }
      const {data: history, error: historyError} = await supabase.from('akatsuki_broadcasts').select('id,title,state,done_at,done_by,due_at,category').neq('state','scheduled').order('updated_at',{ascending:false}).limit(100);
      if (historyError) box.appendChild(el('div','msg',historyError.message));
      const past = (history || []).filter(r => r.state !== 'scheduled').sort((a, b) => (b.done_at || b.due_at).localeCompare(a.done_at || a.due_at));
      const archive = el('details', 'task-folder');
      const archiveSummary = el('summary'); archiveSummary.append(el('span', null, 'Archive'), el('span', 'muted', `${past.length} completed or closed`)); archive.appendChild(archiveSummary);
      const archiveItems = el('div', 'folder-items');
      if (!past.length) archiveItems.appendChild(el('div', 'muted', 'The archive is empty.'));
      for (const r of past) {
        const it = el('div', 'item'); const tx = el('div', 't'); tx.appendChild(el('b', null, r.title));
        const folderLabel = CATEGORIES[r.category || 'general'] || CATEGORIES.general;
        tx.appendChild(el('div', 'muted', `${folderLabel} · ` + (r.state === 'done' ? `done ${fmt(r.done_at)} in ${r.done_by || '?'}` : r.state === 'skipped' ? 'skipped this occurrence' : 'cancelled'))); it.appendChild(tx); archiveItems.appendChild(it);
      }
      archive.appendChild(archiveItems); box.appendChild(archive);

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
