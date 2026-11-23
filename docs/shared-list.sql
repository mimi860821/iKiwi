-- Database setup for the iKiwi shared list.
-- Run the whole script in the Supabase SQL Editor. It is safe to run again: it
-- creates what is missing and upgrades an older database (trash, who added an
-- entry, room members with an emoji each).
-- The tables are locked; the app only talks to the functions below, which need a
-- room code.

create table if not exists public.ikiwi_items (
  room text not null,
  id uuid not null,
  name text not null default '',
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  category text not null default '',
  note text not null default '',
  deleted boolean not null default false,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  created_by text not null default '',
  primary key (room, id)
);

-- Upgrades for databases made by earlier versions of this script.
alter table public.ikiwi_items add column if not exists created_at timestamptz;
update public.ikiwi_items set created_at = updated_at where created_at is null;
alter table public.ikiwi_items alter column created_at set default now();
alter table public.ikiwi_items alter column created_at set not null;
alter table public.ikiwi_items add column if not exists deleted_at timestamptz;
alter table public.ikiwi_items add column if not exists created_by text not null default '';
update public.ikiwi_items set deleted_at = updated_at where deleted and deleted_at is null;

create index if not exists ikiwi_items_room_updated
  on public.ikiwi_items (room, updated_at);

alter table public.ikiwi_items enable row level security;
revoke all on public.ikiwi_items from anon, authenticated;

-- Members of a room: one emoji each, never the same emoji twice in a room.
create table if not exists public.ikiwi_members (
  room text not null,
  member_id uuid not null,
  emoji text not null,
  joined_at timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  primary key (room, member_id),
  unique (room, emoji)
);

alter table public.ikiwi_members enable row level security;
revoke all on public.ikiwi_members from anon, authenticated;

-- Read a room. Entries that have been in the trash for more than 30 days are
-- deleted for good here.
drop function if exists public.ikiwi_pull(text, timestamptz);

create or replace function public.ikiwi_pull(
  p_room text,
  p_since timestamptz default 'epoch',
  p_member uuid default null
)
returns setof public.ikiwi_items
language plpgsql security definer set search_path = public as $$
begin
  if length(p_room) < 20 then raise exception 'bad room'; end if;

  delete from public.ikiwi_items
  where room = p_room and deleted and deleted_at is not null
    and deleted_at < now() - interval '30 days';

  if p_member is not null then
    update public.ikiwi_members set last_seen = now()
    where room = p_room and member_id = p_member;
  end if;

  return query
    select * from public.ikiwi_items
    where room = p_room and updated_at > p_since
    order by updated_at;
end $$;

-- Save entries. An entry marked "purge" is deleted for good, but only if it is
-- already in the trash.
create or replace function public.ikiwi_push(p_room text, p_items jsonb)
returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
  it jsonb;
  t timestamptz := clock_timestamp();
  v_deleted boolean;
begin
  if length(p_room) < 20 then raise exception 'bad room'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 200 then
    raise exception 'bad items';
  end if;

  for it in select * from jsonb_array_elements(p_items) loop
    if coalesce((it->>'purge')::boolean, false) then
      delete from public.ikiwi_items
      where room = p_room and id = (it->>'id')::uuid and deleted;
      continue;
    end if;

    v_deleted := coalesce((it->>'deleted')::boolean, false);

    insert into public.ikiwi_items
      (room, id, name, lat, lng, category, note, deleted, updated_at, deleted_at, created_by)
    values (
      p_room, (it->>'id')::uuid,
      left(coalesce(it->>'name', ''), 200),
      (it->>'lat')::float8, (it->>'lng')::float8,
      left(coalesce(it->>'category', ''), 100),
      left(coalesce(it->>'note', ''), 1000),
      v_deleted, t,
      case when v_deleted then t end,
      left(coalesce(it->>'created_by', ''), 16)
    )
    on conflict (room, id) do update set
      name = excluded.name, lat = excluded.lat, lng = excluded.lng,
      category = excluded.category, note = excluded.note,
      deleted = excluded.deleted,
      deleted_at = case when excluded.deleted
                        then coalesce(public.ikiwi_items.deleted_at, t) end,
      created_by = case when public.ikiwi_items.created_by = ''
                        then excluded.created_by
                        else public.ikiwi_items.created_by end,
      updated_at = t;
  end loop;

  return t;
end $$;

-- Join a room: returns this member's emoji. Joining again with the same member id
-- gives the same emoji back. A new member gets a random emoji nobody in the room
-- has, and not p_avoid (the one this person had last time).
create or replace function public.ikiwi_join(
  p_room text,
  p_member uuid,
  p_avoid text default ''
)
returns text
language plpgsql security definer set search_path = public as $$
declare
  pool text[] := array['🐶','🐱','🐭','🐹','🐰','🦊','🐻','🐼','🐨','🐯','🦁','🐮','🐷','🐸','🐵','🐔','🐧','🐦','🦆','🦉','🦄','🐝','🦋','🐢','🐙','🦀','🐬','🐳','🦈','🐊','🦒','🦘','🦥','🦦','🐘','🦓','🐴','🐺','🦝','🦔','🐞','🐌','🦜','🦩','🦚','🦢','🐠','🐡','🍎','🍊','🍋','🍉','🍇','🍓','🍑','🍒','🥝','🍍','🥑','🌽','🥕','🍄','🌻','🌸','🌵','🍀'];
  existing text;
  candidates text[];
  pick text;
  tries int := 0;
begin
  if length(p_room) < 20 then raise exception 'bad room'; end if;

  select emoji into existing from public.ikiwi_members
  where room = p_room and member_id = p_member;
  if existing is not null then
    update public.ikiwi_members set last_seen = now()
    where room = p_room and member_id = p_member;
    return existing;
  end if;

  -- Members not seen for 30 days no longer hold an emoji.
  delete from public.ikiwi_members
  where room = p_room and last_seen < now() - interval '30 days';

  loop
    select array_agg(e) into candidates
    from unnest(pool) as e
    where e not in (select emoji from public.ikiwi_members where room = p_room)
      and e <> p_avoid;

    if candidates is null then
      -- Only the avoided one is left: better to reuse it than to refuse.
      select array_agg(e) into candidates
      from unnest(pool) as e
      where e not in (select emoji from public.ikiwi_members where room = p_room);
    end if;
    if candidates is null then raise exception 'room full'; end if;

    pick := candidates[1 + floor(random() * array_length(candidates, 1))::int];
    begin
      insert into public.ikiwi_members (room, member_id, emoji)
      values (p_room, p_member, pick);
      return pick;
    exception when unique_violation then
      tries := tries + 1;
      if tries > 5 then raise; end if;
    end;
  end loop;
end $$;

-- Leave a room: the emoji becomes free again.
create or replace function public.ikiwi_leave(p_room text, p_member uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if length(p_room) < 20 then raise exception 'bad room'; end if;
  delete from public.ikiwi_members where room = p_room and member_id = p_member;
end $$;

revoke all on function public.ikiwi_pull(text, timestamptz, uuid) from public;
revoke all on function public.ikiwi_push(text, jsonb) from public;
revoke all on function public.ikiwi_join(text, uuid, text) from public;
revoke all on function public.ikiwi_leave(text, uuid) from public;
grant execute on function public.ikiwi_pull(text, timestamptz, uuid) to anon;
grant execute on function public.ikiwi_push(text, jsonb) to anon;
grant execute on function public.ikiwi_join(text, uuid, text) to anon;
grant execute on function public.ikiwi_leave(text, uuid) to anon;

notify pgrst, 'reload schema';
