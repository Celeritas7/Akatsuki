// Akatsuki config — copy your values from Supabase → Project Settings → API.
// The anon key is safe to ship ONLY because every akatsuki_* table has real RLS.
// Bump every build. sw.js names its cache after it; the console logs it on start.
window.AKATSUKI_BUILD = 'R027';
window.AKATSUKI_CONFIG = {
  SUPABASE_URL: '',        // e.g. 'https://xxxx.supabase.co'
  SUPABASE_ANON_KEY: '',   // 'eyJ…'
  PORT: 8092
};
