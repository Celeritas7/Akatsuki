/* scriptura-adapter.js — Scriptura's side of the hub.  R019 · Sep 26
 *
 * Two parts, loaded separately:
 *
 *   ScripturaAudio  — the learner player. No Supabase client, no sign-in, no hub.
 *                     Reads the public bucket only. Load it in index.html.
 *   ScripturaHub    — the publisher. Admin/tools page only, signed in.
 *                     createClient(URL, KEY, { global: { headers: { 'x-akatsuki-app': 'scriptura' } } })
 *                     <script src="lib/akatsuki-client.js"></script>
 *                     <script src="lib/scriptura-adapter.js"></script>
 *
 * Rules: one request per pack, never per word · ≤ 2000 items (split as <pack>.1, .2)
 *        the Azure key never enters a page · missing clip → device voice, not Azure.
 */
(function () {
  const BASE = 'https://wylxvmkcrexwfpjpbhyy.supabase.co/storage/v1/object/public/akatsuki-audio/';
  const keyOf = (t) => [...String(t).normalize('NFC')].map(c => c.codePointAt(0).toString(16)).join('-');

  /* ── learner ─────────────────────────────────────────────────────────── */
  function ScripturaAudio(opts = {}) {
    const idx = {}, loading = {};
    const fallback = opts.fallback || ((text, lang) => window.ScripturaSpeech && window.ScripturaSpeech.speakDevice && window.ScripturaSpeech.speakDevice(text, lang));

    /** Call when a language's content has loaded. One fetch; refreshes at most every 5 min. */
    function load(lang) {
      const hit = idx[lang];
      if (hit && Date.now() - hit.at < 300000) return Promise.resolve(hit.map);
      if (loading[lang]) return loading[lang];
      loading[lang] = fetch(BASE + lang + '/_index.json?t=' + Math.floor(Date.now() / 60000), { cache: 'no-store' })
        .then(r => (r.ok ? r.json() : {}))
        .catch(() => (hit ? hit.map : {}))
        .then(map => { idx[lang] = { map, at: Date.now() }; delete loading[lang]; return map; });
      return loading[lang];
    }
    const url = (lang, text) => {
      const k = keyOf(text), v = idx[lang] && idx[lang].map[k];
      return v ? BASE + lang + '/' + k + '.mp3?v=' + v : null;
    };
    let current = null;
    return {
      keyOf, load, url,
      has: (lang, text) => !!url(lang, text),
      /** Clip if the index has it, else the device voice. Never throws. */
      async play(lang, text) {
        await load(lang);
        const u = url(lang, text);
        if (!u) return fallback(text, lang), 'device';
        try { if (current) current.pause(); current = new Audio(u); await current.play(); return 'clip'; }
        catch { fallback(text, lang); return 'device'; }
      }
    };
  }

  /* ── publisher (tools page) ──────────────────────────────────────────── */
  function ScripturaHub(supabase, opts = {}) {
    const hub = window.Akatsuki(supabase, 'scriptura', { log: opts.log || (() => {}) });
    const h = (s) => { let x = 5381; for (let i = 0; i < s.length; i++) x = ((x << 5) + x + s.charCodeAt(i)) | 0; return (x >>> 0).toString(36); };
    const CUR = 'akatsuki_replyseq_scriptura';
    const IDS = 'akatsuki_audio_ids_scriptura';   // current id per lang:pack:rev (after -2, -3…)
    const ids = () => { try { return JSON.parse(localStorage.getItem(IDS) || '{}'); } catch { return {}; } };

    return {
      hub, keyOf,
      /** One pack → one request. texts: [{text, kind: 'letter'|'word'}]. Returns the publish result + id. */
      async requestPack(lang, pack, texts, { voice, rate = '-15%', format = 'audio-24khz-48kbitrate-mono-mp3' } = {}) {
        const seen = new Set(), items = [];
        for (const t of texts) {
          const text = String(t.text || '').normalize('NFC').trim(); if (!text) continue;
          const key = keyOf(text); if (seen.has(key)) continue; seen.add(key);
          items.push({ text, key, kind: t.kind === 'letter' ? 'letter' : 'word' });
        }
        if (items.length > 2000) throw Object.assign(new Error(`${pack}: ${items.length} items — split as ${pack}.1, ${pack}.2`), { code: 'AK110' });
        const rev = h(items.map(i => i.key).sort().join(','));
        const base = `scr-audio:${lang}:${pack}:${rev}`, all = ids();
        const id = all[base] || base;
        const payload = { lang, pack, rev, items, rate, format, ...(voice ? { voice } : {}) };
        const r = await hub.publish({ to: 'tts', kind: 'audio.wanted', addr: { id }, payload, key: id });
        if (r.status === 'closed') return { ...r, id, note: 'already ready — nothing to make' };
        all[base] = id; localStorage.setItem(IDS, JSON.stringify(all));
        return { ...r, id, items: items.length };
      },
      /** Re-send a pack whose reply is 'partial' (failed clips) under <id>-2, -3… */
      async retryPack(lang, pack, texts, o) {
        const items = texts.map(t => keyOf(String(t.text || '').normalize('NFC').trim())).filter(Boolean);
        const rev = h([...new Set(items)].sort().join(','));
        const base = `scr-audio:${lang}:${pack}:${rev}`, all = ids();
        const cur = all[base] || base, m = cur.match(/-(\d+)$/);
        all[base] = m ? cur.replace(/-\d+$/, '-' + (Number(m[1]) + 1)) : cur + '-2';
        localStorage.setItem(IDS, JSON.stringify(all));
        return this.requestPack(lang, pack, texts, o);
      },
      /** Progress for the tools page: calls onReply({id, status, total, ready, failed}) per changed reply. */
      async watchReplies(onReply) {
        const since = Number(localStorage.getItem(CUR) || 0);
        const rows = await hub.replies('audio.wanted', since);
        let max = since;
        for (const r of rows) {
          onReply({ id: r.src_addr && r.src_addr.id, ...(r.reply || {}) });
          max = Math.max(max, Number(r.reply_seq) || 0);
        }
        localStorage.setItem(CUR, String(max));
        return rows.length;
      }
    };
  }

  window.ScripturaAudio = ScripturaAudio;
  window.ScripturaHub = ScripturaHub;
})();
