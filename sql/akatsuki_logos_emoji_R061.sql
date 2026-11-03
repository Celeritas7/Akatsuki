-- ============================================================================
-- Akatsuki R061 · logos: retire a duplicate identity, emojis for the apps with no web address — 2026-11-03.
-- Idempotent.  Applied live 2026-11-03 (hub session, on the person's go — handover open item 9).
--
--   A. 'psycology_team' retired: a duplicate of 'psychology_app' (same name "Psycology team";
--      psychology_app has the real home_url).  Retired, not deleted (R049: no deletes).
--   B. 35 identities with no home_url, no logo and no emoji get logo_source = 'emoji'.
--      The daily akatsuki-logo-sync never touches emoji rows; WF or the person can change any of them.
--
-- Written directly, not through akatsuki_app_identity_upsert: every row's owner_app is 'wf', and the
-- hub does not act as wf.  updated_by = 'akatsuki' marks the change.  Guarded so a row that has got
-- a logo, an emoji or a web address since the 2026-11-03 read is left alone.
-- Not done here: the typo'd name "Mehcnaical - machanism" (the person did not ask), and the
-- 17 apps that have a web address (their fix is an icon on their own page).
-- ============================================================================

-- ═══ A · retire the duplicate ═════════════════════════════════════════════
update public.akatsuki_app_identity
   set retired_at = now(), updated_at = now(), updated_by = 'akatsuki'
 where user_id = 'e91a5f37-e63a-4fd0-8488-4d7a51d56822' and app_key = 'psycology_team' and retired_at is null;

-- ═══ B · emojis ════════════════════════════════════════════════════════════
update public.akatsuki_app_identity i
   set logo_source = 'emoji', emoji = e.emoji, updated_at = now(), updated_by = 'akatsuki'
  from (values
    ('alarm_time_assistance_app',       '⏰'),
    ('apps',                            '🧩'),
    ('argmin',                          '📉'),
    ('bank_tasks',                      '🏦'),
    ('before_leaving_japan',            '🧳'),
    ('chinese_study_app',               '🀄'),
    ('command_centre_advanced',         '🛰️'),
    ('commonplace_-_machine_learning',  '🤖'),
    ('commonplace-cmti',                '📒'),
    ('contact_atlas',                   '📇'),
    ('data_collector_app',              '🗂️'),
    ('deployops',                       '🚀'),
    ('disaster_management_app',         '🆘'),
    ('dynamic_chatbot',                 '💬'),
    ('eagle_eye_plus',                  '🦅'),
    ('ethics_app',                      '⚖️'),
    ('events',                          '📅'),
    ('exercise_team',                   '🏋️'),
    ('ghost_tracker_advanced',          '👻'),
    ('hypnos',                          '😴'),
    ('india_tasks',                     '🇮🇳'),
    ('job_change',                      '💼'),
    ('language-utils',                  '🔤'),
    ('manim_projects',                  '🎞️'),
    ('mechanical_-_machine_design',     '⚙️'),
    ('mechanical_-_machine_design_app', '🛠️'),
    ('mechanical_-_manufacturing',      '🏭'),
    ('mehcnaical_-_machanism',          '🔩'),
    ('mind_map_advanced',               '🕸️'),
    ('neurology_team',                  '🧠'),
    ('nutritrack',                      '🥗'),
    ('posture_correction_app',          '🧍'),
    ('sample_collection_app',           '🧪'),
    ('sigma',                           '🧮'),
    ('som',                             '🔷')
  ) as e(app_key, emoji)
 where i.user_id = 'e91a5f37-e63a-4fd0-8488-4d7a51d56822' and i.app_key = e.app_key
   and i.retired_at is null and i.logo_path is null and i.logo_source is null and i.emoji is null and i.home_url is null;
