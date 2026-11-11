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
    [hidden] { display: none !important; }
    .actions { display:flex; flex-wrap:wrap; gap:8px; margin-top:10px; }
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
    fieldset { display:flex; flex-wrap:wrap; gap:8px; border:1px solid #3a2d33; border-radius:10px; margin:0; padding:10px; }
    fieldset label { flex-direction:row; align-items:center; min-height:44px; padding:0 6px; }
    fieldset input { width:20px; height:20px; accent-color:#c3242b; }
    .date-row { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:10px; }
    .date-row label { min-width:0; }
    .date-row input { min-width:0; width:100%; box-sizing:border-box; }
    .schedule-summary { padding:14px; border:1px solid #644047; border-radius:12px; background:#21151b; line-height:1.55; font-size:14px; white-space:pre-line; }
    .save-bar { position:sticky; bottom:0; padding:10px 0; background:#0f0b10; }
    .save-bar button { width:100%; min-height:48px; }
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
    let folderId = null, editor = null, renderVersion = 0, sourceTask = null;
    function navigate(folder, form = null) { folderId = folder; editor = form; render(); }
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
      const version = ++renderVersion;
      const box = sheet.querySelector('.box'); box.replaceChildren();
      const current = () => sheet && version === renderVersion;
      const back = el('button', 'small', editor ? '← Back to folder' : '← All folders');
      back.onclick = () => navigate(editor ? folderId : null);
      if (folderId && !sourceTask) box.appendChild(back);
      const head = el('div', 'head'); head.append(el('h2', null, editor ? (editor.id ? 'Edit ' : 'Add ') + (editor.kind !== 'task' ? 'rule' : 'task') : (CATEGORIES[folderId] || '📣 Broadcasts')));
      const x = el('button', 'small x', 'Close'); x.onclick = close; head.appendChild(x); box.appendChild(head);
      box.appendChild(el('div', 'muted', 'A broadcast appears when its time and place conditions match. Complete it, snooze it, or choose Skip. Unfinished windows use your default snooze.'));

      const { data: list, error } = await supabase.from('akatsuki_broadcasts')
        .select('id,title,body,due_at,show_at,state,snoozes,done_at,done_by,push_note,category,repeat_days,timezone,task_id')
        .in('state', ['scheduled', 'paused']).order('show_at');
      if (!current()) return;
      if (error) { box.appendChild(el('div', 'msg', error.message)); return; }
      const sched = list || [];
      const conditionResult = await supabase.from('akatsuki_task_conditions').select('*');
      if (!current()) return;
      if (conditionResult.error) { box.appendChild(el('div','msg',conditionResult.error.message)); return; }
      const conditions = conditionResult.data || [];
      for (const row of sched) row.conditions = conditions.find(c => c.task_id === row.task_id) || null;
      if (!folderId) {
        const folders = el('div', 'folders');
        for (const [value, label] of Object.entries(CATEGORIES)) {
          const entries = sched.filter(r => (r.category || 'general') === value);
          const folder = el('button', 'folder'); folder.dataset.category = value;
          const pending = entries.filter(r => r.state === 'scheduled' && Date.parse(r.show_at) <= Date.now()).length;
          folder.append(document.createTextNode(label), el('span', null, `${pending} pending · ${entries.length} tasks and rules`));
          folder.onclick = () => navigate(value);
          folders.appendChild(folder);
        }
        box.appendChild(folders);
      } else if (!editor) {
        const actions = el('div', 'actions');
        const task = el('button', 'primary', '+ Add task'); task.onclick = () => navigate(folderId, {kind:'task'});
        const rule = el('button', 'primary', '+ Add rule'); rule.onclick = () => navigate(folderId, {kind:'rule'});
        actions.append(task, rule); box.appendChild(actions);
      }
      const { data: places } = await supabase.from('akatsuki_places').select('id,label,lat,lng,retired_at').is('retired_at', null).not('lat', 'is', null).order('ord', { nullsFirst: false });
      if (!current()) return;
      (places || []).forEach(p => { p.hub = hubOf(p); p.key = 'p:' + p.id; });
      const { data: areaRows } = await supabase.from('akatsuki_areas').select('id,label,country,lat,lng,retired_at').is('retired_at', null).not('lat', 'is', null).order('label');
      if (!current()) return;
      const areas = (areaRows || []).map(a => ({ ...a, key: 'a:' + a.id, hub: ({ JP: 'jp', IN: 'in', HK: 'hk' })[String(a.country || '').toUpperCase()] || hubOf(a) }));
      if (editor) {
        const editing = editor;
        if(sourceTask) box.appendChild(el('div','schedule-summary',`From ${app} · ${sourceTask.status || 'Not scheduled'}${sourceTask.last_result?' · Last result: '+sourceTask.last_result:''}. This reminder tracks your task; it does not record a purchase or expense for you.`));
        const condition = editing.conditions;
        // One request key survives retries until this form is successfully submitted.
        const requestId = crypto.randomUUID();
        const category = {value: folderId};
        box.appendChild(el('div', 'muted', `Folder · ${CATEGORIES[folderId]}`));
        const repeat = el('select');
        for (const [value, label] of [['0','Once only'],['1','Every day'],['7','Every week'],['custom','Every N days']]) { const o = el('option', null, label); o.value = value; repeat.appendChild(o); }
        repeat.value = editing.repeat_days ? ([1,7].includes(editing.repeat_days) ? String(editing.repeat_days) : 'custom') : editing.kind === 'rule' ? '1' : '0';
        const lr = el('label', null, 'Repeat'); lr.appendChild(repeat);
        const days = el('input'); days.type = 'number'; days.min = '1'; days.max = '3650'; days.step = '1'; days.value = String(editing.repeat_days || 14);
        const ld = el('label', null, 'Every how many days?'); ld.appendChild(days); ld.hidden = true;
        repeat.onchange = () => { ld.hidden = repeat.value !== 'custom'; };
        const zone = editing.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone || 'Asia/Tokyo';
        const conversionHint = el('div', 'muted', 'Saving as a timed reminder stops this arrival rule and replaces its pending arrival messages. Completed history is kept.');
        conversionHint.hidden = true;
        const recurrenceHint = el('div', 'muted', `Uses ${zone}. Unfinished items stay pending. After Done or Skip, the next future scheduled day is used.`);
        // add
        const t = el('input'); t.maxLength = 120; t.placeholder = 'What needs doing'; t.value = editing.title || '';
        const b = el('textarea'); b.maxLength = 1000; b.placeholder = 'Details (optional)'; b.value = editing.body || '';
        const w = el('input'); w.type = 'datetime-local';
        const soon = new Date(Date.now() + 3600e3); soon.setMinutes(Math.ceil(soon.getMinutes() / 5) * 5, 0, 0); w.value = localInput(editing.id ? new Date(editing.due_at || soon) : soon);
        const lt = el('label', null, 'Title'); lt.appendChild(t);
        const lb = el('label', null, 'Message'); lb.appendChild(b);
        // Keep one internal local datetime value for the existing save contract.
        const lw = el('div');
        const dueHeading=el('h3',null,'Date and time');lw.appendChild(dueHeading);
        const dateRow=el('div','date-row');
        const dateInput=el('input');dateInput.type='date';dateInput.value=w.value.slice(0,10);
        const timeInput=el('input');timeInput.type='time';timeInput.value=w.value.slice(11,16);
        const dateLabel=el('label',null,'Date');dateLabel.appendChild(dateInput);
        const timeLabel=el('label',null,'Time');timeLabel.appendChild(timeInput);dateRow.append(dateLabel,timeLabel);
        const shortcuts=el('div','actions');
        const syncDate=()=>{w.value=dateInput.value&&timeInput.value?dateInput.value+'T'+timeInput.value:'';w.dispatchEvent(new Event('input'));};
        for(const [label,offset] of [['Today',0],['Tomorrow',1],['In 7 days',7]]) {
          const btn=el('button',null,label);btn.type='button';btn.onclick=()=>{const d=new Date();d.setDate(d.getDate()+offset);dateInput.value=localInput(d).slice(0,10);syncDate();};shortcuts.appendChild(btn);
        }
        const inHour=el('button',null,'In 1 hour');inHour.type='button';inHour.onclick=()=>{const d=localInput(new Date(Date.now()+3600e3));dateInput.value=d.slice(0,10);timeInput.value=d.slice(11,16);syncDate();};shortcuts.appendChild(inHour);
        dateInput.addEventListener('input',syncDate);timeInput.addEventListener('input',syncDate);
        lw.append(shortcuts,dateRow,el('div','muted',`Date and time use this device's timezone: ${Intl.DateTimeFormat().resolvedOptions().timeZone}.`));
        // R062: when = a time, or arrival at a saved place
        const when = el('select'); [['time', 'At a time'], ['arrive', 'When I arrive at a place'], ['window', 'During a time window'], ['presence', 'At a place during a time window'], ['arrival_window', 'Arrive during a time window']].forEach(([v, l]) => { const o = el('option', null, l); o.value = v; when.appendChild(o); });
        if (sourceTask || folderId !== 'general' || (editing.id && editing.kind !== 'arrival')) when.querySelector('option[value=arrive]').remove();
        if (editing.kind === 'arrival') { when.value = 'arrive'; }
        if (condition) when.value = ({time:'window',presence:'presence',arrival:'arrival_window'})[condition.mode];
        const lwhen = el('label', null, 'When'); lwhen.appendChild(when);
        const pl = el('select'), md = el('select');
        [['daily_first', 'First arrival of each day'], ['once', 'Next arrival only']].forEach(([v, l]) => { const o = el('option', null, l); o.value = v; md.appendChild(o); });
        // hub switch: only hubs that have places; remembered on this device; Japan first by default
        const targets = [...(places || []), ...areas];
        const hubs = HUBS.filter(h => targets.some(p => p.hub === h.id));
        if (targets.some(p => p.hub === 'other')) hubs.push({ id: 'other', label: '🌐 Other' });
        const hb = el('select'); hubs.forEach(h => { const o = el('option', null, h.label); o.value = h.id; hb.appendChild(o); });
        if (editing.kind === 'arrival') md.value = editing.mode;
        const saved = condition ? targets.find(p => p.key === (condition.area_id ? 'a:' + condition.area_id : 'p:' + condition.place_id))?.hub : editing.kind === 'arrival' ? targets.find(p => p.key === (editing.area_id ? 'a:' + editing.area_id : 'p:' + editing.place_id))?.hub : hubGet(); hb.value = hubs.some(h => h.id === saved) ? saved : (hubs[0] ? hubs[0].id : '');
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
        if (editing.kind === 'arrival') pl.value = editing.area_id ? 'a:' + editing.area_id : 'p:' + editing.place_id;
        if (condition && condition.mode !== 'time') pl.value = condition.area_id ? 'a:' + condition.area_id : 'p:' + condition.place_id;
        const lhb = el('label', null, 'Hub'); lhb.appendChild(hb);
        const lpl = el('label', null, 'Place'); lpl.appendChild(pl);
        const lmd = el('label', null, 'Arrival frequency'); lmd.appendChild(md);
        const fromTime=el('input');fromTime.type='time';fromTime.value=condition?.window_start?.slice(0,5)||'18:00';
        const toTime=el('input');toTime.type='time';toTime.value=condition?.window_end?.slice(0,5)||'22:00';
        const fromLabel=el('label',null,'Window starts');fromLabel.appendChild(fromTime);
        const toLabel=el('label',null,'Window ends');toLabel.appendChild(toTime);
        const weekBox=el('fieldset');weekBox.appendChild(el('legend',null,'Allowed days'));
        const dayChoices=[];
        ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'].forEach((name,i)=>{
          const label=el('label',null,name);const input=el('input');input.type='checkbox';input.value=String(i+1);input.checked=(condition?.weekdays||[1,2,3,4,5,6,7]).includes(i+1);label.appendChild(input);weekBox.appendChild(label);dayChoices.push(input);
        });
        const dayPresets=el('div','actions');
        for(const [label,values] of [['Every day',[1,2,3,4,5,6,7]],['Weekdays',[1,2,3,4,5]],['Weekends',[6,7]]]) {
          const btn=el('button',null,label);btn.type='button';btn.onclick=()=>{dayChoices.forEach(d=>d.checked=values.includes(Number(d.value)));updateSummary();};dayPresets.appendChild(btn);
        }
        const conditionHint=el('div','muted','A window crossing midnight belongs to its start day. Unfinished windows use your default snooze. Place rules require a location update within 5 minutes.');
        const showWhen = () => {
          const a=when.value==='arrive', combined=['window','presence','arrival_window'].includes(when.value), place=a||when.value==='presence'||when.value==='arrival_window';
          conversionHint.hidden=editing.kind!=='arrival'||a;
          lw.style.display=lr.style.display=recurrenceHint.style.display=a?'none':'';
          ld.hidden=a||repeat.value!=='custom';lhb.style.display=lpl.style.display=place?'':'none';lmd.style.display=a?'':'none';
          fromLabel.hidden=toLabel.hidden=weekBox.hidden=conditionHint.hidden=dayPresets.hidden=!combined;
          dueHeading.textContent=combined?'Start checking from':'Date and time';
          recurrenceHint.textContent=`Repeats use ${zone}. After Done or Skip, the next future scheduled date is used. ${combined?'Allowed days and hours limit when it appears; unfinished windows use your default snooze.':'Unfinished tasks remain pending until snoozed, completed or skipped.'}`;
        };
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
        const summary=el('div','schedule-summary');summary.setAttribute('role','status');summary.setAttribute('aria-live','polite');
        const updateSummary=()=>{
          const place=pl.selectedOptions[0]?.textContent||'choose a place';
          const combined=['window','presence','arrival_window'].includes(when.value);
          let message;
          if(when.value==='arrive') message=`When you arrive at ${place}: ${md.value==='once'?'next arrival only':'first arrival of each day'}.`;
          else {
            const valid=w.value&&!Number.isNaN(new Date(w.value).getTime());
            const start=valid?fmt(new Date(w.value).toISOString()):'choose a date and time';
            const interval=Number(repeat.value==='custom'?days.value:repeat.value);
            const repeats=repeat.value==='custom'&&(!Number.isInteger(interval)||interval<1||interval>3650)?'Choose an interval of 1–3650 days.':interval===0?'One occurrence.':`After Done or Skip, repeat on the next future date in the schedule (every ${interval===1?'day':interval===7?'week':interval+' days'}).`;
            if(combined){
              const names=dayChoices.filter(d=>d.checked).map(d=>['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][Number(d.value)-1]).join(', ')||'choose allowed days';
              const where=when.value==='presence'?`Only while you are at ${place}. Being there before the window opens counts.`:when.value==='arrival_window'?`Only when you arrive at ${place} during the window.`:'No place required.';
              message=`Start checking from ${start}.\n${names}, ${fromTime.value||'…'}–${toTime.value||'…'} (${zone})${toTime.value<fromTime.value?' — ends the following day':''}. ${where}\n${repeats} Unfinished windows are logged and snoozed using your setting.`;
            }else message=`Show at ${start}. ${repeats}`;
          }
          summary.textContent=message;
        };
        for(const control of [when,pl,hb,md,repeat,days,fromTime,toTime,...dayChoices]) {control.addEventListener('change',updateSummary);control.addEventListener('input',updateSummary);}
        w.addEventListener('input',updateSummary);
        const addMsg = el('div', 'msg'); const add = el('button', 'primary', editing.id ? 'Save changes' : editing.kind === 'rule' ? 'Add rule' : 'Add task');
        add.onclick = async () => {
          addMsg.className = 'msg'; addMsg.textContent = '';
          if (!t.value.trim()) { addMsg.textContent = 'Give it a title.'; return; }
          if (when.value === 'arrive') {
            if (!pl.value) { addMsg.textContent = 'Pick a place.'; return; }
            add.disabled = true;
            const isArea = pl.value.startsWith('a:'), id = pl.value.slice(2);
            let r;
            try {
              const args = { p_place_id: isArea ? null : id, p_area_id: isArea ? id : null, p_title: t.value, p_body: b.value || null, p_mode: md.value };
              r = editing.kind === 'arrival'
                ? await supabase.rpc('akatsuki_broadcast_rule_edit', {...args, p_id: editing.id})
                : await supabase.rpc('akatsuki_broadcast_rule_add', {...args, p_app: app});
            } catch (error) { r = {error}; }
            add.disabled = false;
            if (r.error) { addMsg.textContent = r.error.message; return; }
            navigate(folderId); return;
          }
          if (!w.value || Number.isNaN(new Date(w.value).getTime())) { addMsg.textContent = 'Choose a date and time.'; return; }
          if ((!editing.id || editing.kind === 'arrival') && new Date(w.value).getTime() < Date.now() - 60e3) { addMsg.textContent = 'That time has already passed — check the date.'; return; }
          add.disabled = true;
          const interval = Number(repeat.value === 'custom' ? days.value : repeat.value);
          if (!Number.isInteger(interval) || interval < (repeat.value === 'custom' ? 1 : 0) || interval > 3650) { add.disabled = false; addMsg.textContent = 'Choose an interval of 1–3650 days.'; return; }
          let error;
          try {
            const combined=['window','presence','arrival_window'].includes(when.value);
            if (sourceTask || combined || condition) {
              const selectedDays=dayChoices.filter(x=>x.checked).map(x=>Number(x.value));
              if (combined && (!fromTime.value||!toTime.value||fromTime.value===toTime.value||!selectedDays.length)) throw new Error('Choose different start/end times and at least one day.');
              if (combined && when.value!=='window' && !pl.value) throw new Error('Choose a place.');
              const c=combined?{mode:({window:'time',presence:'presence',arrival_window:'arrival'})[when.value],window_start:fromTime.value,window_end:toTime.value,weekdays:selectedDays,place_id:when.value!=='window'&&pl.value.startsWith('p:')?pl.value.slice(2):null,area_id:when.value!=='window'&&pl.value.startsWith('a:')?pl.value.slice(2):null}:null;
              if(sourceTask) {
                ({error}=await supabase.rpc('akatsuki_app_task_save',{p_source_app:app,p_source_task_id:sourceTask.sourceTaskId,p_task_type:sourceTask.type||'other',p_source_url:sourceTask.url||null,p_title:t.value,p_body:b.value,p_due_at:editing.due_at&&w.value===localInput(new Date(editing.due_at))?editing.due_at:new Date(w.value).toISOString(),p_repeat_days:interval,p_timezone:zone,p_category:folderId,p_request_id:requestId,p_conditions:c,p_expected_id:editing.id||null}));
              } else ({error}=await supabase.rpc('akatsuki_conditioned_save',{p_id:editing.kind==='arrival'?null:editing.id||null,p_arrival_id:editing.kind==='arrival'?editing.id:null,p_title:t.value,p_body:b.value,p_due_at:editing.due_at&&w.value===localInput(new Date(editing.due_at))?editing.due_at:new Date(w.value).toISOString(),p_repeat_days:interval,p_timezone:zone,p_category:folderId,p_app:app,p_request_id:requestId,p_conditions:c}));
            } else if (editing.kind === 'arrival') {
              ({error} = await supabase.rpc('akatsuki_broadcast_rule_to_time', {p_id:editing.id,p_title:t.value,p_body:b.value,p_due_at:new Date(w.value).toISOString(),p_repeat_days:interval,p_timezone:zone,p_app:app}));
            } else if (editing.id) {
              ({error} = await supabase.rpc('akatsuki_broadcast_manage', {p_id:editing.id,p_action:'edit',p_title:t.value,p_body:b.value,p_due_at:w.value === localInput(new Date(editing.due_at)) ? editing.due_at : new Date(w.value).toISOString(),p_repeat_days:interval}));
            } else ({ error } = await supabase.rpc('akatsuki_broadcast_create', { p_title: t.value, p_body: b.value || null, p_due_at: new Date(w.value).toISOString(), p_app: app, p_category: category.value, p_repeat_days: interval, p_timezone: zone, p_request_id: requestId }));
          } catch (e) { error = e; }
          add.disabled = false;
          if (error) { addMsg.textContent = error.message; return; }
          if(sourceTask) { close(); opts.onSaved?.(); } else navigate(folderId);
        };
        const saveBar=el('div','save-bar');saveBar.append(add,addMsg);
        box.append(lt,lb,lwhen,conversionHint,lhb,lpl,lmd,lw,fromLabel,toLabel,dayPresets,weekBox,conditionHint,lr,ld,recurrenceHint,summary,saveBar);showWhen();updateSummary();
        return;
      }

      // R062: arrival rules
      const { data: rules } = await supabase.from('akatsuki_broadcast_rules').select('id,place_id,area_id,title,body,mode,state,last_fired_at,fired_count')
        .eq('state', 'active').order('created_at');
      if (!current()) return;
      if (folderId === 'general' && (rules || []).length) {
        const label = (r) => { const p = r.area_id ? areas.find(q => q.id === r.area_id) : (places || []).find(q => q.id === r.place_id);
          if (!p) return r.place_id || 'area'; const h = HUBS.find(x => x.id === p.hub); return (h ? h.label.split(' ')[0] + ' ' : '') + p.label + (r.area_id ? ' (area)' : ''); };
        box.appendChild(el('h3', null, 'When I arrive'));
        for (const r of rules) {
          const it = el('div', 'item'); const tx = el('div', 't'); tx.appendChild(el('b', null, r.title));
          tx.appendChild(el('div', 'muted', `${label(r)} · ${r.mode === 'once' ? 'next arrival only' : 'first arrival each day'}` + (r.last_fired_at ? ` · last ${fmt(r.last_fired_at)}` : ' · not fired yet')));
          const controls = el('div', 'actions');
          const edit = el('button', 'small', 'Edit');
          edit.onclick = () => navigate('general', {...r, kind:'arrival'});
          const c = el('button', 'small', 'Cancel');
          c.onclick = async () => { if (!confirm(`Stop "${r.title}"?`)) return; const { error } = await supabase.rpc('akatsuki_broadcast_rule_cancel', { p_id: r.id }); if (error) alert(error.message); render(); };
          controls.append(edit, c); tx.appendChild(controls); it.append(tx); box.appendChild(it);
        }
      }

      if (folderId) {
      for (const [kind, label] of [['task', 'Tasks'], ['rule', 'Rules']]) {
        const grouped = sched.filter(r => (r.category || 'general') === folderId && (r.repeat_days > 0) === (kind === 'rule'));
        const folder = el('section', 'task-folder');
        folder.appendChild(el('h3', null, `${label} · ${grouped.length}`));
        const items = el('div', 'folder-items');
        if (!grouped.length) items.appendChild(el('div', 'muted', `No ${label.toLowerCase()} in this folder yet.`));
        for (const r of grouped) {
          const it = el('div', 'item'); const tx = el('div', 't'); tx.appendChild(el('b', null, r.title));
          tx.appendChild(el('div', 'muted', (r.snoozes ? `snoozed to ${fmt(r.show_at)} · due ${fmt(r.due_at)}` : fmt(r.due_at)) + (r.push_note ? ' · ' + r.push_note : '')));
          if (r.conditions) tx.appendChild(el('div','muted',`${({time:'Time window',presence:'At place',arrival:'Arrival'})[r.conditions.mode]} · ${r.conditions.window_start.slice(0,5)}–${r.conditions.window_end.slice(0,5)} · ${r.conditions.weekdays.map(d=>['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][d-1]).join(', ')} · ${r.conditions.timezone}`));
          const actions = el('div', 'actions');
          const edit = el('button', 'small', 'Edit'); edit.onclick = () => navigate(folderId, {...r, kind}); actions.appendChild(edit);
          const itemError = el('div', 'msg'); itemError.setAttribute('role', 'status');
          for (const [action, label] of [[r.state === 'paused' ? 'resume' : 'pause', r.state === 'paused' ? 'Resume' : 'Pause'], ['delete', 'Delete']]) {
            const control = el('button', 'small', label);
            control.onclick = async () => {
              if (action === 'delete' && !confirm(`Delete "${r.title}" and stop its future reminders?`)) return;
              control.disabled = true;
              try {
                const {error} = await supabase.rpc('akatsuki_broadcast_manage', {p_id:r.id,p_action:action});
                if (error) throw error;
                render();
              } catch (e) { itemError.textContent = e.message; control.disabled = false; }
            };
            actions.appendChild(control);
          }
          tx.appendChild(el('div', 'muted', (r.state === 'paused' ? 'Paused' : Date.parse(r.show_at) <= Date.now() ? 'Pending' : 'Scheduled') + (r.repeat_days ? ` · every ${r.repeat_days} day(s)` : ' · once')));
          const change = el('select'); change.setAttribute('aria-label', `Move ${r.title} to folder`);
          for (const [value, folderLabel] of Object.entries(CATEGORIES)) { const o = el('option', null, folderLabel); o.value = value; change.appendChild(o); }
          change.value = r.category || 'general';
          change.onchange = async () => { change.disabled = true; const {error} = await supabase.rpc('akatsuki_broadcast_category', {p_id:r.id,p_category:change.value}); if(error) alert(error.message); render(); };
          tx.appendChild(change);
          tx.append(actions, itemError); it.append(tx); items.appendChild(it);
        }
        folder.appendChild(items); box.appendChild(folder);
      }
      }
      const {data: history, error: historyError} = await supabase.from('akatsuki_broadcasts').select('id,title,state,done_at,done_by,due_at,category').in('state',['done','skipped','cancelled']).order('updated_at',{ascending:false}).limit(100);
      if (!current()) return;
      if (historyError) box.appendChild(el('div','msg',historyError.message));
      const past = (history || []).filter(r => !folderId || (r.category || 'general') === folderId).sort((a, b) => (b.done_at || b.due_at).localeCompare(a.done_at || a.due_at));
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

      // History is deliberately separate from Archive: it records repeated actions.
      const eventResult = await supabase.from('akatsuki_task_events').select('id,event_type,happened_at,app,details,task_id').order('happened_at',{ascending:false}).limit(100);
      if (!current()) return;
      const log = el('details', 'task-folder'); log.appendChild(el('summary', null, 'Activity history'));
      const logItems = el('div', 'folder-items');
      if (eventResult.error) logItems.appendChild(el('div','msg',eventResult.error.message));
      const events = (eventResult.data || []).filter(e => !folderId || (e.details?.category || 'general') === folderId);
      if (!events.length && !eventResult.error) logItems.appendChild(el('div','muted','No activity recorded yet. History starts with this update.'));
      for (const e of events) {
        const item = el('div','item'); const tx = el('div','t');
        tx.append(el('b',null,e.details?.title || 'Task'),el('div','muted',`${e.event_type.replaceAll('_',' ')} · ${fmt(e.happened_at)}${e.app ? ' · ' + e.app : ''}`));
        if (e.event_type === 'snoozed' && e.details?.show_at) tx.appendChild(el('div','muted','Remind again: ' + fmt(e.details.show_at)));
        item.appendChild(tx); logItems.appendChild(item);
      }
      log.appendChild(logItems); box.appendChild(log);
      if (folderId) return;
      box.appendChild(el('h3',null,'Reminder settings'));
      const settingResult = await supabase.from('akatsuki_reminder_settings').select('default_snooze_minutes').limit(1);
      if (!current()) return;
      const defaultMinutes = el('input'); defaultMinutes.type='number'; defaultMinutes.min='1'; defaultMinutes.max='10080'; defaultMinutes.step='1';
      defaultMinutes.value=String(settingResult.data?.[0]?.default_snooze_minutes || 60);
      const settingLabel=el('label',null,'Default snooze (minutes)'); settingLabel.appendChild(defaultMinutes);
      const settingMsg=el('div','msg'); settingMsg.setAttribute('role','status');
      if (settingResult.error) settingMsg.textContent=settingResult.error.message;
      const saveSettings=el('button','small','Save snooze setting');
      saveSettings.onclick=async()=>{
        const minutes=Number(defaultMinutes.value);
        if (!Number.isInteger(minutes)||minutes<1||minutes>10080) {settingMsg.textContent='Choose 1–10080 minutes.';return;}
        saveSettings.disabled=true;settingMsg.textContent='';
        try {const {error}=await supabase.rpc('akatsuki_reminder_settings_set',{p_minutes:minutes});if(error)throw error;settingMsg.textContent='Saved for all connected apps.';}
        catch(e){settingMsg.textContent=e.message;} finally{saveSettings.disabled=false;}
      };
      box.append(settingLabel,el('div','muted','Used by Snooze and Do later. Starts at 60 minutes until you change it.'),saveSettings,settingMsg);
      // push
      box.appendChild(el('h3', null, 'Phone notifications'));
      const pm = el('div', 'msg'); const rowb = el('div', 'rowb');
      const st = await pushState().catch(e => ({ can: false, why: e.message }));
      if (!current()) return;
      const { data: devs } = await supabase.from('akatsuki_push_subscriptions').select('device,last_ok_at,last_error,created_at').order('created_at');
      if (!current()) return;
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
      sourceTask=null;
      if (sheet) return;
      sheet = el('div', 'sheet'); sheet.appendChild(el('div', 'box'));
      sheet.addEventListener('click', (e) => { if (e.target === sheet) close(); });
      folderId = null; editor = null; root.appendChild(sheet); render();
    }
    function close() { sourceTask=null; ++renderVersion; if (sheet) { sheet.remove(); sheet = null; } }

    return {
      mount() {
        if (host) return this;
        host = document.createElement('div'); host.setAttribute('data-akatsuki-broadcast-panel', '');
        root = host.attachShadow({ mode: 'open' });
        const s = document.createElement('style'); s.textContent = CSS; root.appendChild(s);
        const fab = el('button', 'fab', '📣'); fab.title = 'Broadcasts'; fab.setAttribute('aria-label', 'Broadcasts');
        fab.style.bottom = `calc(${opts.bottom ?? 16}px + env(safe-area-inset-bottom, 0px))`;
        fab.onclick = open; if(!opts.hideLauncher) root.appendChild(fab);
        document.body.appendChild(host);
        if (location.hash === '#broadcast') open();
        return this;
      },
      unmount() { if (host) host.remove(); host = null; root = null; sheet = null; },
      async openTask(seed) {
        if(seed.sourceTaskId==null || !String(seed.sourceTaskId).trim()) throw new Error('Task ID required');
        this.mount();close();open();
        const version=++renderVersion;const box=sheet.querySelector('.box');box.replaceChildren(el('div','muted','Loading task status…'));
        try {
          const {data:status,error}=await supabase.from('akatsuki_task_status').select('*').eq('source_app',app).eq('source_task_id',String(seed.sourceTaskId)).maybeSingle();if(error) throw error;
          if(!sheet||version!==renderVersion)return;
          let row=null,c=null;
          if(status?.occurrence_id && ['scheduled','pending','snoozed','paused','waiting_for_conditions'].includes(status.status)) {
            const result=await supabase.from('akatsuki_broadcasts').select('*').eq('id',status.occurrence_id).maybeSingle();if(result.error)throw result.error;row=result.data;
            if(!row || !['scheduled','paused'].includes(row.state))throw new Error('Task changed. Close and reopen to refresh.');
            const cr=await supabase.from('akatsuki_task_conditions').select('*').eq('task_id',status.id).maybeSingle();if(cr.error)throw cr.error;c=cr.data;
          }
          if(!sheet||version!==renderVersion)return;
          sourceTask={...seed,sourceTaskId:String(seed.sourceTaskId),status:status?.status,last_result:status?.last_result};
          navigate(row?.category||seed.category||'general',row?{...row,conditions:c,kind:'task'}:{title:seed.title,body:seed.body||'',kind:'task'});
        } catch(error) { if(sheet&&version===renderVersion){box.replaceChildren(el('div','msg',error.message||String(error)));const back=el('button',null,'Close');back.onclick=close;box.appendChild(back);} }
      },
      open, close
    };
  }
  window.AkatsukiBroadcastPanel = AkatsukiBroadcastPanel;
})();
