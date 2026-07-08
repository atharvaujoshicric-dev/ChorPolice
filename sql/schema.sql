-- ============================================================
-- ALPHA — CHOR vs POLICE — SUPABASE SCHEMA v3
-- 10 Safe Zones each giving one unique sticker, passport + token
-- (=lifelines) system, 2-min jail, restart from any Safe Zone,
-- 3 lifelines then eliminated, ADMIN-only rule overrides,
-- real enforced "Safe Ticket" protection, per-zone hints routed
-- to different chors, optional per-zone vouchers/coupons.
--
-- Run this whole file in Supabase SQL Editor (Project > SQL Editor > New query)
-- Safe to re-run: drops & recreates functions/policies, adds any
-- missing columns from earlier versions.
-- ============================================================

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- MIGRATION CLEANUP (safe if you previously ran an older schema)
-- ------------------------------------------------------------
drop function if exists finalize_checkpost_group(uuid, uuid[]);
drop function if exists undo_last_catch(uuid);
drop function if exists reset_game();
drop function if exists collect_sticker(uuid, uuid);
drop function if exists catch_chor(uuid, uuid);
drop table if exists checkpost_visits cascade;

alter table if exists game_settings drop column if exists group_size_required;
alter table if exists game_settings add column if not exists safe_zone_grace_seconds int not null default 90;

alter table if exists catches add column if not exists lifelines_before int not null default 0;

alter table if exists checkposts add column if not exists hint_text text;
alter table if exists checkposts add column if not exists voucher_text text;
alter table if exists checkposts add column if not exists next_hint_cursor int not null default 0;

alter table if exists players add column if not exists protected_until timestamptz;
alter table if exists players add column if not exists protected_checkpost_id uuid references checkposts(id) on delete set null;
alter table if exists players add column if not exists next_hint_checkpost_id uuid references checkposts(id) on delete set null;

-- ------------------------------------------------------------
-- Small helper: raises if the given player id is not an admin.
-- Used by every rule-overriding action so that even a direct RPC
-- call (not just the UI button) is blocked for non-admins.
-- ------------------------------------------------------------
create or replace function assert_is_admin(p_player_id uuid) returns void as $$
declare
  v_role text;
begin
  select pl.role into v_role from players pl where pl.id = p_player_id;
  if v_role is distinct from 'admin' then
    raise exception 'Not authorized: admin only';
  end if;
end;
$$ language plpgsql security definer;

-- ------------------------------------------------------------
-- GAME SETTINGS (single row config)
-- ------------------------------------------------------------
create table if not exists game_settings (
  id int primary key default 1,
  penalty_seconds int not null default 120,
  lifelines_default int not null default 3,
  safe_zone_grace_seconds int not null default 90,
  status text not null default 'setup' check (status in ('setup','running','ended'))
);
insert into game_settings (id) values (1) on conflict (id) do nothing;

-- ------------------------------------------------------------
-- CHECKPOSTS (Safe Zones)
-- hint_text: clue shown to a chor routed here next (admin-set)
-- voucher_text: optional coupon/reward shown once collected
-- next_hint_cursor: rotation pointer so different chors leaving
--   this zone get routed to different next zones
-- ------------------------------------------------------------
create table if not exists checkposts (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  order_no int not null default 0,
  hint_text text,
  voucher_text text,
  next_hint_cursor int not null default 0,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- PLAYERS (chor / police / volunteer / admin) — code-based login
-- protected_until / protected_checkpost_id: the real, enforced
--   "Safe Ticket" — while set in the future, catch_chor rejects.
-- next_hint_checkpost_id: which zone's hint this chor currently sees.
-- ------------------------------------------------------------
create table if not exists players (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  role text not null check (role in ('chor','police','volunteer','admin')),
  assigned_checkpost_id uuid references checkposts(id) on delete set null,
  lifelines int not null default 3,
  status text not null default 'active' check (status in ('active','eliminated','winner')),
  penalty_until timestamptz,
  protected_until timestamptz,
  protected_checkpost_id uuid references checkposts(id) on delete set null,
  next_hint_checkpost_id uuid references checkposts(id) on delete set null,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- STICKERS — one per (chor, safe zone), collected once each
-- ------------------------------------------------------------
create table if not exists stickers (
  id uuid primary key default gen_random_uuid(),
  chor_id uuid not null references players(id) on delete cascade,
  checkpost_id uuid not null references checkposts(id) on delete cascade,
  collected_at timestamptz not null default now(),
  unique (chor_id, checkpost_id)
);

-- ------------------------------------------------------------
-- CATCH LOG
-- ------------------------------------------------------------
create table if not exists catches (
  id uuid primary key default gen_random_uuid(),
  chor_id uuid not null references players(id) on delete cascade,
  police_id uuid not null references players(id) on delete cascade,
  caught_at timestamptz not null default now(),
  lifelines_before int not null,
  lifelines_after int not null,
  resulted_in_elimination boolean not null default false
);

-- ------------------------------------------------------------
-- SEED: admin account (CHANGE THE CODE AFTER FIRST LOGIN)
-- ------------------------------------------------------------
insert into players (code, name, role, lifelines)
values ('ADMIN1', 'Game Admin', 'admin', 0)
on conflict (code) do nothing;

-- ------------------------------------------------------------
-- WINNER TRIGGERS: mark chor as winner once all zones collected,
-- and revert winner status if an admin removes a sticker later.
-- ------------------------------------------------------------
create or replace function check_winner() returns trigger as $$
declare
  v_total int;
  v_collected int;
  v_status text;
begin
  select count(*) into v_total from checkposts;
  select count(*) into v_collected from stickers where chor_id = new.chor_id;
  select status into v_status from players where id = new.chor_id;

  if v_total > 0 and v_collected >= v_total and v_status = 'active' then
    update players set status = 'winner', next_hint_checkpost_id = null where id = new.chor_id;
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_check_winner on stickers;
create trigger trg_check_winner
  after insert on stickers
  for each row execute function check_winner();

create or replace function check_unwinner() returns trigger as $$
declare
  v_total int;
  v_collected int;
begin
  select count(*) into v_total from checkposts;
  select count(*) into v_collected from stickers where chor_id = old.chor_id;
  if v_collected < v_total then
    update players set status = 'active' where id = old.chor_id and status = 'winner';
  end if;
  return old;
end;
$$ language plpgsql;

drop trigger if exists trg_check_unwinner on stickers;
create trigger trg_check_unwinner
  after delete on stickers
  for each row execute function check_unwinner();

-- ------------------------------------------------------------
-- RPC: collect a sticker at a safe zone (single instant scan)
-- - Idempotent: scanning the same chor+zone twice is a safe no-op.
-- - Grants/refreshes the chor's Safe Ticket protection window.
-- - Assigns their next hint by rotating through their remaining,
--   not-yet-collected zones, so different chors leaving the same
--   zone get pointed at different next zones.
-- - Surfaces this zone's voucher (if any) when newly collected.
-- ------------------------------------------------------------
create or replace function collect_sticker(
  p_chor_id uuid,
  p_checkpost_id uuid
) returns table (
  newly_awarded boolean,
  chor_name text,
  total_stickers int,
  total_checkposts int,
  chor_status text,
  protected_until timestamptz,
  zone_occupancy int,
  voucher_text text,
  next_hint_text text,
  next_hint_checkpost_name text
) as $$
declare
  v_status text;
  v_penalty_until timestamptz;
  v_name text;
  v_inserted boolean := false;
  v_grace_seconds int;
  v_protected_until timestamptz;
  v_cursor int;
  v_next_checkpost_id uuid;
  v_voucher text;
begin
  select pl.status, pl.penalty_until, pl.name into v_status, v_penalty_until, v_name
  from players pl where pl.id = p_chor_id and pl.role = 'chor';

  if v_name is null then
    raise exception 'Chor not found';
  end if;
  if v_status = 'eliminated' then
    raise exception '% has been eliminated', v_name;
  end if;
  if v_penalty_until is not null and v_penalty_until > now() then
    raise exception '% is still in jail', v_name;
  end if;

  insert into stickers (chor_id, checkpost_id)
  values (p_chor_id, p_checkpost_id)
  on conflict (chor_id, checkpost_id) do nothing;

  get diagnostics v_inserted = row_count;
  v_inserted := (v_inserted::int = 1);

  -- grant/refresh Safe Ticket protection — this is what actually
  -- blocks a catch attempt while the chor is at this zone
  select gs.safe_zone_grace_seconds into v_grace_seconds from game_settings gs where gs.id = 1;
  v_protected_until := now() + (v_grace_seconds || ' seconds')::interval;

  update players pl
    set protected_until = v_protected_until,
        protected_checkpost_id = p_checkpost_id
    where pl.id = p_chor_id;

  -- rotate this zone's cursor so the next chor who leaves gets a
  -- different next-zone hint than the one before them
  update checkposts cp set next_hint_cursor = next_hint_cursor + 1
    where cp.id = p_checkpost_id
    returning next_hint_cursor into v_cursor;

  with remaining as (
    select cp.id, cp.name,
           row_number() over (order by cp.order_no) - 1 as rn,
           count(*) over () as cnt
    from checkposts cp
    where cp.id <> p_checkpost_id
      and not exists (
        select 1 from stickers s2 where s2.chor_id = p_chor_id and s2.checkpost_id = cp.id
      )
  )
  select r.id into v_next_checkpost_id
  from remaining r
  where r.rn = (v_cursor % greatest(r.cnt, 1))
  limit 1;

  update players pl set next_hint_checkpost_id = v_next_checkpost_id where pl.id = p_chor_id;

  if v_inserted then
    select cp.voucher_text into v_voucher from checkposts cp where cp.id = p_checkpost_id;
  end if;

  return query
  select
    v_inserted,
    v_name,
    (select count(*)::int from stickers s where s.chor_id = p_chor_id),
    (select count(*)::int from checkposts),
    (select pl2.status from players pl2 where pl2.id = p_chor_id),
    v_protected_until,
    (select count(*)::int from players pl3
       where pl3.protected_checkpost_id = p_checkpost_id and pl3.protected_until > now()),
    v_voucher,
    (select cp2.hint_text from checkposts cp2 where cp2.id = v_next_checkpost_id),
    (select cp3.name from checkposts cp3 where cp3.id = v_next_checkpost_id);
end;
$$ language plpgsql security definer;

-- ------------------------------------------------------------
-- RPC: police catches a chor (via scanning chor's personal QR)
-- Blocks the catch entirely if the chor currently holds an
-- active Safe Ticket (protected_until in the future) — this is
-- the real, enforced version of "safe inside a Safe Zone".
-- ------------------------------------------------------------
create or replace function catch_chor(
  p_chor_id uuid,
  p_police_id uuid
) returns table (id uuid, name text, lifelines int, status text, penalty_until timestamptz) as $$
declare
  v_lifelines int;
  v_status text;
  v_penalty_until timestamptz;
  v_protected_until timestamptz;
  v_name text;
  v_new_lifelines int;
  v_eliminated boolean := false;
  v_penalty_seconds int;
begin
  select pl.lifelines, pl.status, pl.penalty_until, pl.protected_until, pl.name
    into v_lifelines, v_status, v_penalty_until, v_protected_until, v_name
  from players pl
  where pl.id = p_chor_id
  for update;

  if v_lifelines is null then
    raise exception 'Chor not found';
  end if;
  if v_status = 'eliminated' then
    raise exception 'Chor already eliminated';
  end if;
  if v_status = 'winner' then
    raise exception 'Chor already won the game';
  end if;
  if v_penalty_until is not null and v_penalty_until > now() then
    raise exception 'Chor is already serving a penalty';
  end if;
  if v_protected_until is not null and v_protected_until > now() then
    raise exception '% has a Safe Ticket right now (% seconds left) — cannot be caught',
      v_name, ceil(extract(epoch from (v_protected_until - now())));
  end if;

  select gs.penalty_seconds into v_penalty_seconds from game_settings gs where gs.id = 1;

  v_new_lifelines := v_lifelines - 1;

  if v_new_lifelines <= 0 then
    v_eliminated := true;
    update players pl
      set lifelines = 0, status = 'eliminated', penalty_until = null
      where pl.id = p_chor_id;
  else
    update players pl
      set lifelines = v_new_lifelines,
          penalty_until = now() + (v_penalty_seconds || ' seconds')::interval
      where pl.id = p_chor_id;
  end if;

  insert into catches (chor_id, police_id, lifelines_before, lifelines_after, resulted_in_elimination)
  values (p_chor_id, p_police_id, v_lifelines, v_new_lifelines, v_eliminated);

  return query
    select pl.id, pl.name, pl.lifelines, pl.status, pl.penalty_until
    from players pl where pl.id = p_chor_id;
end;
$$ language plpgsql security definer;

-- ------------------------------------------------------------
-- ADMIN-ONLY OVERRIDES
-- Every function below re-checks role='admin' server-side, so
-- even a direct RPC call from a non-admin session is rejected.
-- ------------------------------------------------------------

create or replace function admin_undo_catch(p_admin_id uuid, p_catch_id uuid)
returns table (chor_id uuid, chor_name text) as $$
declare
  v_catch record;
begin
  perform assert_is_admin(p_admin_id);

  select c.* into v_catch from catches c where c.id = p_catch_id for update;
  if v_catch.id is null then
    raise exception 'Catch not found';
  end if;

  update players pl
    set lifelines = v_catch.lifelines_before,
        status = 'active',
        penalty_until = null
    where pl.id = v_catch.chor_id;

  delete from catches c where c.id = v_catch.id;

  return query select v_catch.chor_id, (select pl2.name from players pl2 where pl2.id = v_catch.chor_id);
end;
$$ language plpgsql security definer;

create or replace function admin_clear_jail(p_admin_id uuid, p_chor_id uuid)
returns void as $$
begin
  perform assert_is_admin(p_admin_id);
  update players pl set penalty_until = null where pl.id = p_chor_id;
end;
$$ language plpgsql security definer;

create or replace function admin_restore_chor(p_admin_id uuid, p_chor_id uuid)
returns void as $$
declare
  v_lifelines_default int;
begin
  perform assert_is_admin(p_admin_id);
  select gs.lifelines_default into v_lifelines_default from game_settings gs where gs.id = 1;
  update players pl
    set status = 'active', lifelines = v_lifelines_default, penalty_until = null
    where pl.id = p_chor_id;
end;
$$ language plpgsql security definer;

create or replace function admin_eliminate_chor(p_admin_id uuid, p_chor_id uuid)
returns void as $$
begin
  perform assert_is_admin(p_admin_id);
  update players pl
    set status = 'eliminated', lifelines = 0, penalty_until = null
    where pl.id = p_chor_id;
end;
$$ language plpgsql security definer;

-- Reset progress only: keeps every player & zone, wipes stickers/
-- catches/lifelines/jail/protection/hints so you can re-run the event.
create or replace function reset_game(p_admin_id uuid) returns void as $$
begin
  perform assert_is_admin(p_admin_id);
  delete from catches;
  delete from stickers;
  update players
    set lifelines = (select lifelines_default from game_settings where id = 1),
        status = 'active',
        penalty_until = null,
        protected_until = null,
        protected_checkpost_id = null,
        next_hint_checkpost_id = null
    where role = 'chor';
end;
$$ language plpgsql security definer;

-- Full wipe: deletes every player except the admin seed, every
-- Safe Zone, and all logs — use this to start completely fresh
-- for a brand-new event. (The Supabase Table Editor's own "delete
-- all rows" button will refuse with "DELETE requires a WHERE
-- clause" — that's a PostgREST safety guard on the REST API, not
-- something wrong with your data. This function runs as plain SQL
-- inside the database instead, so it isn't affected by that guard.)
create or replace function admin_full_wipe(p_admin_id uuid) returns void as $$
begin
  perform assert_is_admin(p_admin_id);
  delete from catches;
  delete from stickers;
  delete from players where role <> 'admin';
  delete from checkposts;
end;
$$ language plpgsql security definer;

-- ------------------------------------------------------------
-- VIEW: chor progress (used by admin/chor dashboards)
-- ------------------------------------------------------------
create or replace view chor_progress as
select
  p.id as chor_id,
  p.name,
  p.code,
  p.status,
  p.lifelines,
  p.penalty_until,
  p.protected_until,
  count(s.id) as stickers,
  (select count(*) from checkposts) as total_checkposts
from players p
left join stickers s on s.chor_id = p.id
where p.role = 'chor'
group by p.id;

-- ------------------------------------------------------------
-- ROW LEVEL SECURITY
-- Private live-event game run by trusted staff — anon key gets
-- full read/write. Tighten for a public deployment.
-- ------------------------------------------------------------
alter table game_settings enable row level security;
alter table checkposts enable row level security;
alter table players enable row level security;
alter table stickers enable row level security;
alter table catches enable row level security;

drop policy if exists "anon_all_game_settings" on game_settings;
create policy "anon_all_game_settings" on game_settings for all using (true) with check (true);

drop policy if exists "anon_all_checkposts" on checkposts;
create policy "anon_all_checkposts" on checkposts for all using (true) with check (true);

drop policy if exists "anon_all_players" on players;
create policy "anon_all_players" on players for all using (true) with check (true);

drop policy if exists "anon_all_stickers" on stickers;
create policy "anon_all_stickers" on stickers for all using (true) with check (true);

drop policy if exists "anon_all_catches" on catches;
create policy "anon_all_catches" on catches for all using (true) with check (true);

grant usage on schema public to anon, authenticated;
grant all on all tables in schema public to anon, authenticated;
grant execute on all functions in schema public to anon, authenticated;
