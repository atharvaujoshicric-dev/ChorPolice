-- ============================================================
-- CHOR POLICE (ALPHA) — SUPABASE SCHEMA v2
-- Matches the official blueprint: 10 Safe Zones each giving one
-- unique sticker, capacity 10/zone (human-enforced), passport +
-- token (=lifelines) system, 2-min jail, unlimited restarts from
-- any Safe Zone, 3 total lifelines then eliminated.
--
-- Run this whole file in Supabase SQL Editor (Project > SQL Editor > New query)
-- Safe to re-run: drops & recreates functions/policies.
-- ============================================================

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- MIGRATION CLEANUP (safe if you previously ran the old v1 schema)
-- ------------------------------------------------------------
drop function if exists finalize_checkpost_group(uuid, uuid[]);
drop table if exists checkpost_visits cascade;
alter table if exists game_settings drop column if exists group_size_required;
alter table if exists catches drop column if exists lifelines_before;
alter table if exists catches add column if not exists lifelines_before int not null default 0;

-- ------------------------------------------------------------
-- GAME SETTINGS (single row config)
-- ------------------------------------------------------------
create table if not exists game_settings (
  id int primary key default 1,
  penalty_seconds int not null default 120,
  lifelines_default int not null default 3,
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
-- CATCH LOG (also drives the "undo last catch" safety net)
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
-- WINNER TRIGGER: mark chor as winner once all zones collected
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
    update players set status = 'winner' where id = new.chor_id;
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_check_winner on stickers;
create trigger trg_check_winner
  after insert on stickers
  for each row execute function check_winner();

-- ------------------------------------------------------------
-- RPC: collect a sticker at a safe zone (single instant scan)
-- Idempotent: scanning the same chor at the same zone twice is
-- a no-op the second time (fixes double-scan duplicates).
-- ------------------------------------------------------------
create or replace function collect_sticker(
  p_chor_id uuid,
  p_checkpost_id uuid
) returns table (
  newly_awarded boolean,
  chor_name text,
  total_stickers int,
  total_checkposts int,
  chor_status text
) as $$
declare
  v_status text;
  v_penalty_until timestamptz;
  v_name text;
  v_inserted boolean := false;
begin
  select status, penalty_until, name into v_status, v_penalty_until, v_name
  from players where id = p_chor_id and role = 'chor';

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

  return query
  select
    v_inserted,
    v_name,
    (select count(*)::int from stickers where chor_id = p_chor_id),
    (select count(*)::int from checkposts),
    (select status from players where id = p_chor_id);
end;
$$ language plpgsql security definer;

-- ------------------------------------------------------------
-- RPC: police catches a chor (via scanning chor's personal QR)
-- ------------------------------------------------------------
create or replace function catch_chor(
  p_chor_id uuid,
  p_police_id uuid
) returns table (id uuid, name text, lifelines int, status text, penalty_until timestamptz) as $$
declare
  v_lifelines int;
  v_status text;
  v_penalty_until timestamptz;
  v_new_lifelines int;
  v_eliminated boolean := false;
  v_penalty_seconds int;
begin
  select lifelines, status, penalty_until into v_lifelines, v_status, v_penalty_until
  from players where id = p_chor_id for update;

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

  select penalty_seconds into v_penalty_seconds from game_settings where id = 1;

  v_new_lifelines := v_lifelines - 1;

  if v_new_lifelines <= 0 then
    v_eliminated := true;
    update players
      set lifelines = 0, status = 'eliminated', penalty_until = null
      where id = p_chor_id;
  else
    update players
      set lifelines = v_new_lifelines,
          penalty_until = now() + (v_penalty_seconds || ' seconds')::interval
      where id = p_chor_id;
  end if;

  insert into catches (chor_id, police_id, lifelines_before, lifelines_after, resulted_in_elimination)
  values (p_chor_id, p_police_id, v_lifelines, v_new_lifelines, v_eliminated);

  return query
    select p.id, p.name, p.lifelines, p.status, p.penalty_until
    from players p where p.id = p_chor_id;
end;
$$ language plpgsql security definer;

-- ------------------------------------------------------------
-- RPC: undo the most recent catch made by this police officer
-- (safety net for double-scans / mis-scans). Only works within
-- 30 seconds of the catch.
-- ------------------------------------------------------------
create or replace function undo_last_catch(p_police_id uuid)
returns table (chor_id uuid, chor_name text) as $$
declare
  v_catch record;
begin
  select * into v_catch
  from catches
  where police_id = p_police_id
    and caught_at > now() - interval '30 seconds'
  order by caught_at desc
  limit 1
  for update;

  if v_catch.id is null then
    raise exception 'No recent catch to undo';
  end if;

  update players
    set lifelines = v_catch.lifelines_before,
        status = 'active',
        penalty_until = null
    where id = v_catch.chor_id;

  delete from catches where id = v_catch.id;

  return query select v_catch.chor_id, (select name from players where id = v_catch.chor_id);
end;
$$ language plpgsql security definer;

-- ------------------------------------------------------------
-- RPC: reset game (keeps players/checkposts, wipes progress)
-- ------------------------------------------------------------
create or replace function reset_game() returns void as $$
begin
  delete from catches;
  delete from stickers;
  update players
    set lifelines = (select lifelines_default from game_settings where id = 1),
        status = 'active',
        penalty_until = null
    where role = 'chor';
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
