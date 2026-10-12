-- R018 · Home point — one query, one answer.  Read-only.  Run, paste the single row.
select
  case
    when n.id is null                then 'NOT IN HUB — never copied'
    when n.retired_at is not null    then 'IN HUB, but the point itself was deleted'
    when a.retired_at is not null    then 'IN HUB, but its area (' || a.label || ') was deleted'
    when a.id is null                then 'IN HUB, but its area is missing'
    else 'IN HUB and visible — should not happen'
  end as answer,
  n.area_id hub_area, a.label hub_area_label, a.retired_at area_deleted_at, n.retired_at point_deleted_at
from (select '7338acb4-212a-4d81-881e-9ce5e332077e'::text id) x
left join akatsuki_anchors n on n.id = x.id
left join akatsuki_areas a on a.user_id = n.user_id and a.id = n.area_id;
