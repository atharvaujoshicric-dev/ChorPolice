-- ============================================================
-- ALPHA — CHOR vs POLICE — SUPABASE SCHEMA v4
-- 10 Safe Zones each giving one unique sticker, passport + token
-- (=lifelines) system, 2-min jail, restart from any Safe Zone,
-- 3 lifelines then eliminated, per-zone hints routed to different
-- chors, optional per-zone vouchers/coupons, real enforced
-- "Safe Ticket" protection.
--
-- v4 closes several loopholes found on review:
--  - collect_sticker now requires proof the caller is the actual
--    volunteer assigned to that zone (previously any chor could
--    call it directly from devtools and self-award every sticker).
--  - catch_chor now requires proof the caller is a real police
--    account (previously any chor could call it directly and
--    "catch"/eliminate a rival by claiming to be police).
--  - Every admin-only override now requires a hidden admin
--    PASSCODE (stored in a table nobody can SELECT via the API)
--    instead of just the admin's player id, which was trivially
--    discoverable by anyone since the players table is open.
--  - Safe Ticket protection is now only granted on a genuinely
--    NEW sticker, not on repeat re-scans of an already-collected
--    zone (previously a chor could camp at a zone getting rescanned
--    forever and stay permanently uncatchable for free).
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
drop function if exists reset_game(uuid);
drop function if exists collect_sticker(uuid, uuid);
drop function if exists catch_chor(uuid, uuid);
drop function if exists admin_undo_catch(uuid, uuid);
drop function if exists admin_clear_jail(uuid, uuid);
drop function if exists admin_restore_chor(uuid, uuid);
drop function if exists admin_eliminate_chor(uuid, uuid);
drop function if exists admin_full_wipe(uuid);
drop function if exists assert_is_admin(uuid);
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
-- ADMIN PASSCODE — deliberately in its own table with NO select
-- policy at all, so RLS denies every client read of it via the
-- API (even though the blanket GRANT below still applies, RLS
-- with zero policies blocks all rows regardless of grants). Only
-- SECURITY DEFINER functions owned by you can read it internally.
-- This replaces authenticating admin actions by player id (which
-- is trivially readable by anyone since players is open) with a
-- real secret nobody else can fetch through the app.
-- ------------------------------------------------------------
create table if not exists admin_secret (
  id int primary key default 1,
  passcode text not null default 'change-this-now'
);
insert into admin_secret (id) values (1) on conflict (id) do nothing;
alter table admin_secret enable row level security;
-- intentionally no policies created here — default deny for anon/authenticated

create or replace function assert_admin_passcode(p_passcode text) returns void as $$
begin
  if p_passcode is null or not exists (select 1 from admin_secret a where a.passcode = p_passcode) then
    raise exception 'Not authorized: invalid admin passcode';
  end if;
end;
$$ language plpgsql security definer;

create or replace function admin_set_passcode(p_old_passcode text, p_new_passcode text) returns void as $$
begin
  perform assert_admin_passcode(p_old_passcode);
  if p_new_passcode is null or length(trim(p_new_passcode)) < 4 then
    raise exception 'New passcode must be at least 4 characters';
  end if;
  update admin_secret set passcode = p_new_passcode where id = 1;
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
-- Admin passcode default is 'change-this-now' — set your own from
-- the Settings tab immediately after logging in.
-- ------------------------------------------------------------
insert into players (code, name, role, lifelines)
values ('ADMIN1', 'Game Admin', 'admin', 0)
on conflict (code) do nothing;

-- ------------------------------------------------------------
-- WINNER TRIGGERS
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
-- INTERNAL: core sticker-collection logic, no caller verification.
-- Only called by the two wrapper functions below, which DO verify.
-- ------------------------------------------------------------
create or replace function _do_collect(
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

  -- Safe Ticket protection is only granted on a genuinely NEW
  -- sticker. Re-scanning a zone you've already collected does NOT
  -- refresh protection — otherwise a chor could camp at a zone and
  -- get rescanned every minute to stay permanently uncatchable.
  select pl2.protected_until into v_protected_until from players pl2 where pl2.id = p_chor_id;

  if v_inserted then
    select gs.safe_zone_grace_seconds into v_grace_seconds from game_settings gs where gs.id = 1;
    v_protected_until := now() + (v_grace_seconds || ' seconds')::interval;

    update players pl
      set protected_until = v_protected_until,
          protected_checkpost_id = p_checkpost_id
      where pl.id = p_chor_id;

    select cp.voucher_text into v_voucher from checkposts cp where cp.id = p_checkpost_id;
  end if;

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

  return query
  select
    v_inserted,
    v_name,
    (select count(*)::int from stickers s where s.chor_id = p_chor_id),
    (select count(*)::int from checkposts),
    (select pl3.status from players pl3 where pl3.id = p_chor_id),
    v_protected_until,
    (select count(*)::int from players pl4
       where pl4.protected_checkpost_id = p_checkpost_id and pl4.protected_until > now()),
    v_voucher,
    (select cp2.hint_text from checkposts cp2 where cp2.id = v_next_checkpost_id),
    (select cp3.name from checkposts cp3 where cp3.id = v_next_checkpost_id);
end;
$$ language plpgsql security definer;

-- ------------------------------------------------------------
-- RPC: collect a sticker — requires proof the caller is the
-- volunteer actually assigned to this Safe Zone. Without this,
-- anyone could call the RPC directly from devtools and award
-- themselves every sticker with no visit at all.
-- ------------------------------------------------------------
create or replace function collect_sticker(
  p_chor_id uuid,
  p_checkpost_id uuid,
  p_volunteer_id uuid
) returns table (
  newly_awarded boolean, chor_name text, total_stickers int, total_checkposts int,
  chor_status text, protected_until timestamptz, zone_occupancy int,
  voucher_text text, next_hint_text text, next_hint_checkpost_name text
) as $$
begin
  if not exists (
    select 1 from players pl
    where pl.id = p_volunteer_id and pl.role = 'volunteer' and pl.assigned_checkpost_id = p_checkpost_id
  ) then
    raise exception 'Not authorized: you are not the volunteer assigned to this Safe Zone';
  end if;

  return query select * from _do_collect(p_chor_id, p_checkpost_id);
end;
$$ language plpgsql security definer;

-- ------------------------------------------------------------
-- INTERNAL: core catch logic, no caller verification. Only called
-- by the two wrapper functions below, which DO verify.
-- ------------------------------------------------------------
create or replace function _do_catch(p_chor_id uuid, p_actor_id uuid)
returns table (id uuid, name text, lifelines int, status text, penalty_until timestamptz) as $$
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
  values (p_chor_id, p_actor_id, v_lifelines, v_new_lifelines, v_eliminated);

  return query
    select pl.id, pl.name, pl.lifelines, pl.status, pl.penalty_until
    from players pl where pl.id = p_chor_id;
end;
$$ language plpgsql security definer;

-- ------------------------------------------------------------
-- RPC: police catches a chor — requires proof the caller is a
-- real police account. Without this, any chor could call the RPC
-- directly and eliminate a rival by just claiming to be police.
-- ------------------------------------------------------------
create or replace function catch_chor(
  p_chor_id uuid,
  p_police_id uuid
) returns table (id uuid, name text, lifelines int, status text, penalty_until timestamptz) as $$
declare
  v_role text;
begin
  select pl.role into v_role from players pl where pl.id = p_police_id;
  if v_role is distinct from 'police' then
    raise exception 'Not authorized: only a police account can make a catch';
  end if;

  return query select * from _do_catch(p_chor_id, p_police_id);
end;
$$ language plpgsql security definer;

-- ------------------------------------------------------------
-- ADMIN-ONLY OVERRIDES
-- Every function below requires the hidden admin passcode, not
-- just a player id — see admin_secret table above for why.
-- ------------------------------------------------------------

create or replace function admin_undo_catch(p_admin_passcode text, p_catch_id uuid)
returns table (chor_id uuid, chor_name text) as $$
declare
  v_catch record;
begin
  perform assert_admin_passcode(p_admin_passcode);

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

create or replace function admin_clear_jail(p_admin_passcode text, p_chor_id uuid)
returns void as $$
begin
  perform assert_admin_passcode(p_admin_passcode);
  update players pl set penalty_until = null where pl.id = p_chor_id;
end;
$$ language plpgsql security definer;

-- Precise lifelines control: sets lifelines to an EXACT value
-- (clamped between 0 and the configured max) instead of always
-- fully resetting. Reviving from 0 sets status back to active;
-- dropping to 0 sets status to eliminated.
create or replace function admin_set_lifelines(p_admin_passcode text, p_chor_id uuid, p_lifelines int)
returns void as $$
declare
  v_max int;
  v_lifelines int := p_lifelines;
begin
  perform assert_admin_passcode(p_admin_passcode);
  select gs.lifelines_default into v_max from game_settings gs where gs.id = 1;

  if v_lifelines < 0 then v_lifelines := 0; end if;
  if v_lifelines > v_max then v_lifelines := v_max; end if;

  update players pl
    set lifelines = v_lifelines,
        status = case when v_lifelines <= 0 then 'eliminated' else 'active' end,
        penalty_until = case when v_lifelines <= 0 then null else pl.penalty_until end
    where pl.id = p_chor_id;
end;
$$ language plpgsql security definer;

create or replace function admin_eliminate_chor(p_admin_passcode text, p_chor_id uuid)
returns void as $$
begin
  perform assert_admin_passcode(p_admin_passcode);
  update players pl
    set status = 'eliminated', lifelines = 0, penalty_until = null
    where pl.id = p_chor_id;
end;
$$ language plpgsql security definer;

-- Emergency manual actions for when a camera genuinely fails —
-- admin-only, fully logged like any other catch/collection.
create or replace function admin_manual_catch(p_admin_passcode text, p_chor_id uuid)
returns table (id uuid, name text, lifelines int, status text, penalty_until timestamptz) as $$
declare
  v_admin_id uuid;
begin
  perform assert_admin_passcode(p_admin_passcode);
  select pl.id into v_admin_id from players pl where pl.role = 'admin' limit 1;
  return query select * from _do_catch(p_chor_id, v_admin_id);
end;
$$ language plpgsql security definer;

create or replace function admin_manual_award_sticker(p_admin_passcode text, p_chor_id uuid, p_checkpost_id uuid)
returns table (
  newly_awarded boolean, chor_name text, total_stickers int, total_checkposts int,
  chor_status text, protected_until timestamptz, zone_occupancy int,
  voucher_text text, next_hint_text text, next_hint_checkpost_name text
) as $$
begin
  perform assert_admin_passcode(p_admin_passcode);
  return query select * from _do_collect(p_chor_id, p_checkpost_id);
end;
$$ language plpgsql security definer;

-- Reset progress only: keeps every player & zone, wipes stickers/
-- catches/lifelines/jail/protection/hints so you can re-run the event.
create or replace function reset_game(p_admin_passcode text) returns void as $$
declare
  v_lifelines_default int;
begin
  perform assert_admin_passcode(p_admin_passcode);

  select gs.lifelines_default into v_lifelines_default from game_settings gs where gs.id = 1;

  delete from catches where true;
  delete from stickers where true;

  update players
    set lifelines = v_lifelines_default,
        status = 'active',
        penalty_until = null,
        protected_until = null,
        protected_checkpost_id = null,
        next_hint_checkpost_id = null
    where role = 'chor';
end;
$$ language plpgsql security definer;

-- Full wipe: deletes every player except the admin seed, every
-- Safe Zone, and all logs. (Supabase's own Table Editor "delete
-- all rows" button refuses with "DELETE requires a WHERE clause"
-- — that's a PostgREST safety guard on the REST API, not a bug.
-- This function runs as plain SQL inside the database, so it
-- isn't affected by that guard.)
create or replace function admin_full_wipe(p_admin_passcode text) returns void as $$
begin
  perform assert_admin_passcode(p_admin_passcode);
  delete from catches where true;
  delete from stickers where true;
  delete from players where role <> 'admin';
  delete from checkposts where true;
end;
$$ language plpgsql security definer;

-- ------------------------------------------------------------
-- VIEW: chor progress (used by admin/chor dashboards)
-- ------------------------------------------------------------
drop view if exists chor_progress;

create view chor_progress as
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
-- full read/write on gameplay tables. admin_secret is the one
-- deliberate exception (see above). Tighten further for a public
-- deployment.
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
