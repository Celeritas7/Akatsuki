-- R022 · C3 · after Roadmap STEP2b (Oct 5). Run all; paste the four results.

-- C3a · Are the 202 unmirrored rows all del:true?
select (payload->>'del')::boolean as del, status, count(*)
  from akatsuki_requests
 where from_app = 'wf' and to_app = 'rm' and kind = 'task.upsert' and seq >= 264
 group by 1, 2 order by 1, 2;

-- C3b · Anything rejected or deferred, with the reason
-- (a deferred row stays 'pending' with attempts > 0; its reason is in error)
select status, attempts > 0 as deferred, coalesce(error, '') as reason, count(*), min(seq), max(seq)
  from akatsuki_requests
 where to_app = 'rm' and seq >= 264 and status in ('rejected','pending')
 group by 1, 2, 3 order by 1, 2;

-- C3c · Unmirrored rows that are NOT del (should be 0) — seqs for Roadmap
select r.seq, r.src_addr, left(coalesce(r.payload->>'title', r.payload->>'t'), 60) as title
  from akatsuki_requests r
 where r.from_app = 'wf' and r.to_app = 'rm' and r.kind = 'task.upsert' and r.seq >= 264
   and coalesce((r.payload->>'del')::boolean, false) = false
   and not exists (select 1 from akatsuki_links l
                    where l.a_app = 'wf' and l.b_app = 'rm' and l.a_addr = r.src_addr and l.orphaned_at is null)
 order by r.seq limit 50;

-- C3d · Flip wf→rm task.upsert to live — only if C3c returned 0 rows
update akatsuki_routes
   set state = 'live',
       note = 'LIVE Oct 5 — WF v98.2 backfill 414 (seq 264+), Roadmap 202610041607 mirrored 212; rest del:true. ' || note
 where from_app = 'wf' and to_app = 'rm' and kind = 'task.upsert' and state <> 'live'
   and not exists (
     select 1 from akatsuki_requests r
      where r.from_app = 'wf' and r.to_app = 'rm' and r.kind = 'task.upsert' and r.seq >= 264
        and coalesce((r.payload->>'del')::boolean, false) = false
        and not exists (select 1 from akatsuki_links l
                         where l.a_app = 'wf' and l.b_app = 'rm' and l.a_addr = r.src_addr and l.orphaned_at is null))
returning from_app, to_app, kind, state;

-- C3e · (Oct 5) C3d returned nothing: 2 non-del rows (seq 320, 404) were rejected by Roadmap
-- because their title is EMPTY. Bad rows, not a broken link. Flip live, recording the 2 in the note.
update akatsuki_routes
   set state = 'live',
       note = 'LIVE Oct 5 — 414 sent (seq 264+): 212 mirrored, 200 del, 2 rejected (seq 320, 404: empty title — WF to stop sending blanks). ' || note
 where from_app = 'wf' and to_app = 'rm' and kind = 'task.upsert' and state <> 'live'
returning from_app, to_app, kind, state;
