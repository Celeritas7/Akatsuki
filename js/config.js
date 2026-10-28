// Akatsuki config — copy your values from Supabase → Project Settings → API.
// The key is the project's PUBLISHABLE key (sb_publishable_…, 2026-10-28 key migration; the field keeps its old name).
// It is safe to ship ONLY because every akatsuki_* table has real RLS.
// Bump every build. sw.js names its cache after it; the console logs it on start.
window.AKATSUKI_BUILD = 'R054c';
window.AKATSUKI_CONFIG = {
  SUPABASE_URL: 'https://wylxvmkcrexwfpjpbhyy.supabase.co',        // e.g. 'https://xxxx.supabase.co'
  SUPABASE_ANON_KEY: 'sb_publishable_e3pDOuxIdstaC7s0a680kQ_R10TrAyv',   // publishable, not the legacy anon JWT
  PORT: 8092
};
