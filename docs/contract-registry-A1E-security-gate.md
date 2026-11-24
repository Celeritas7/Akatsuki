# Contract Registry A1E — Security gate and risk disposition

**Status: PENDING SECURITY SIGN-OFF / NO-GO for A1F.** Assessment is read-only. No production SQL, privilege changes, password settings or new paid services were applied.

## Target boundary

`General_apps` is shared by Akatsuki and other apps. The registry migrations A1A/A1B are still absent from the recorded production migration history, and the three registry tables and registration RPC are absent from a separate read-only catalog check. `Technical` is outside this rollout. Never treat an app's declaration or matching Auth UUIDs across Supabase projects as a cross-project service grant.

## Registry-specific planned permissions (source inspection)

- **A1A** creates exactly three new `public.akatsuki_contract_*` metadata tables. RLS is enabled; SELECT is granted to `authenticated` under `user_id = auth.uid()` owner policies. No anonymous table access or browser DML grants are planned.
- **A1B** adds one narrow `SECURITY DEFINER` registration function. It checks `auth.uid()`, uses an explicit fixed empty `search_path`, accepts only declared metadata fields, inserts proposed owner-scoped records, and revokes `PUBLIC`/`anon` EXECUTE while granting it to `authenticated`.
- **A1C** is a read-only UI with a safe undeployed-registry state. It must not interfere with existing Hub cards, routes, reminders, tasks or data.

**What remains unproved:** effective deployed grants, RLS cross-tenant behavior, anonymous execution denial, and client behavior after A1A/A1B in a disposable staging environment. Execute `tests/contract-registry-a1a.sql`, `tests/contract-registry-a1b.sql`, and `tests/contract-registry-a1e-permissions.sql` **only on staging**, not on live production.

## Shared-project advisor findings (2026-11-24, read-only)

| Advisor category | Number | Registry-deployment relevance |
| --- | ---: | --- |
| Anonymous `SECURITY DEFINER` EXECUTE | 34 (16 Akatsuki-prefixed) | Priority review of existing privileged RPC surface |
| Authenticated `SECURITY DEFINER` EXECUTE | 63 (44 Akatsuki-prefixed) | Owner checks, role grants and side effects must be reviewed |
| Mutable function `search_path` | 36 (18 Akatsuki-prefixed) | Risk classification and staged hardening |
| RLS enabled, no policy | 3 (including `akatsuki_fn_budget`) | Verify whether intended default denial |
| Extensions in `public` | 3 | Broader shared-project hardening; avoid blind extension moves |
| Leaked-password protection disabled | 1 | Shared Auth security; assess account protections and plan impact |

Categories overlap. A linter warning is *not* itself proof of exploitation or of data exposure.

### Focused anonymous-definer triage

Read-only catalog analysis found **16** Akatsuki-prefixed functions callable by the `anon` role and marked `SECURITY DEFINER`. **15** reference `auth.uid()` and have `search_path=public` without explicitly placing `pg_temp` last. **One** returns `trigger` and is not an ordinary RPC invocation. Both `anon` and `authenticated` lack `CREATE` in `public`, but retain database `TEMPORARY` privileges.

This combination is **not sufficient to assert a working vulnerability through the Supabase Data API**. It does mean that the security review must account for privileged function name resolution and temporary-schema behavior, not just the ability to create permanent objects in `public`.

**Required disposition:** review effective entry points and the function bodies, owner checks and search-path qualification, identify whether any unsafe caller-controlled name resolution exists, and test proposed targeted hardening in isolated staging. Record whether each risk is **blocking**, **mitigated by verified controls**, or **tracked separately**. Do not blanket-revoke `anon`/`authenticated` EXECUTE on legacy functions: this may break location, visit, reminder or app-connection workflows.

Security advisor documentation:
- [Publicly callable SECURITY DEFINER functions](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable)
- [Signed-in callers of SECURITY DEFINER functions](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable)
- [Mutable function search paths](https://supabase.com/docs/guides/database/database-linter?lint=0011_function_search_path_mutable)
- [RLS without policies](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy)
- [Extensions in public](https://supabase.com/docs/guides/database/database-linter?lint=0014_extension_in_public)
- [Leaked password protection](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection)

## Security stop/go checklist

- [x] Planned A1A/A1B source permissions and migration order inspected.
- [x] Existing project advisor warnings retrieved and summarized, without changing configuration.
- [x] Anonymous definer grants and temporary-schema capability identified for follow-up.
- [ ] Complete threat review and targeted staging tests of existing privileged functions relevant to the registry owner/session boundary; document residual risk.
- [ ] Apply A1A then A1B to disposable staging, run owner/anonymous/cross-tenant/duplicate/error-path tests and inspect new advisor differences.
- [ ] Verify no route, task, reminder, app connection, Storage policy, or Auth behavior is disrupted by proposed security changes.
- [ ] Obtain security sign-off as part of A1E, separate from the later A1F production deployment approval.

**Verdict: NO-GO.** A merged readiness report is not equivalent to having passed A1E. Do not deploy SQL, upgrade Supabase, incur charges, merge changes, or modify production without the user's explicit approval.
