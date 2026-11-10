-- Edit active arrival rules in place, preserving their firing history.
create or replace function public.akatsuki_broadcast_rule_edit(
 p_id uuid,p_place_id text,p_title text,p_body text default null,
 p_mode text default 'daily_first',p_area_id text default null)
returns void language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null then raise exception 'Sign in first' using errcode='42501'; end if;
 perform 1 from akatsuki_broadcast_rules where id=p_id and user_id=auth.uid() and state='active' for update;
 if not found then raise exception 'Rule is no longer active or unavailable'; end if;
 if char_length(btrim(coalesce(p_title,''))) not between 1 and 120 then raise exception 'Title must be 1–120 characters'; end if;
 if char_length(coalesce(p_body,''))>1000 then raise exception 'Message must be at most 1000 characters'; end if;
 if coalesce(p_mode,'') not in ('daily_first','once') then raise exception 'Invalid repeat mode'; end if;
 if (nullif(p_place_id,'') is null)=(nullif(p_area_id,'') is null) then raise exception 'Choose one place or area'; end if;
 if nullif(p_place_id,'') is not null and not exists(select 1 from akatsuki_places where id=p_place_id and user_id=auth.uid() and retired_at is null and lat is not null and lng is not null) then raise exception 'Place is unavailable or has no coordinates'; end if;
 if nullif(p_area_id,'') is not null and not exists(select 1 from akatsuki_areas where id=p_area_id and user_id=auth.uid() and retired_at is null and lat is not null and lng is not null) then raise exception 'Area is unavailable or has no coordinates'; end if;
 update akatsuki_broadcast_rules set title=btrim(p_title),body=nullif(btrim(coalesce(p_body,'')),''),
 place_id=nullif(p_place_id,''),area_id=nullif(p_area_id,''),mode=p_mode,updated_at=now()
 where id=p_id and user_id=auth.uid();
end $$;
revoke all on function public.akatsuki_broadcast_rule_edit(uuid,text,text,text,text,text) from public,anon;
grant execute on function public.akatsuki_broadcast_rule_edit(uuid,text,text,text,text,text) to authenticated;
notify pgrst,'reload schema';
