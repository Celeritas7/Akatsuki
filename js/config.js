// Akatsuki config — copy your values from Supabase → Project Settings → API.
// The anon key is safe to ship ONLY because every akatsuki_* table has real RLS.
// Bump every build. sw.js names its cache after it; the console logs it on start.
window.AKATSUKI_BUILD = 'R027';
window.AKATSUKI_CONFIG = {
  SUPABASE_URL: 'https://wylxvmkcrexwfpjpbhyy.supabase.co',        // e.g. 'https://xxxx.supabase.co'
  SUPABASE_ANON_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Ind5bHh2bWtjcmV4d2ZwanBiaHl5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2MzkxMDYsImV4cCI6MjA4NDIxNTEwNn0.6Bxo42hx4jwlJGWnfjiTpiDUsYfc1QLTN3YtrU1efak',   // 'eyJ…'
  PORT: 8092
};
