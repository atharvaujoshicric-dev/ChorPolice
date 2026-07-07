-- ============================================================
-- CHOR POLICE GAME — SUPABASE SCHEMA
-- Run this whole file in Supabase SQL Editor (Project > SQL Editor > New query)
-- ============================================================

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- GAME SETTINGS (single row config)
-- ------------------------------------------------------------
create table if not exists game_settings (
  id int primary key default 1,
  group_size_required int not null default 10,
  penalty_seconds int not null default 120,
  lifelines_default int not null default 3,
  status text not null default 'setup' check (status in ('setup','running','ended')),
  single_row boolean generated always as (true) stored unique
);
insert into game_settings (id) values (1) on conflict (id) do nothing;

-- ------------------------------------------------------------
-- CHECKPOSTS
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
-- CHECKPOST VISITS (safe ticket / stamp per chor per checkpost)
-- ------------------------------------------------------------
create table if not exists checkpost_visits (
  id uuid primary key default gen_random_uuid(),
  chor_id uuid not null references players(id) on delete cascade,
  checkpost_id uuid not null references checkposts(id) on delete cascade,
  status text not null check (status in ('safe','stamped','vulnerable')),
  group_size int not null,
  visited_at timestamptz not null default now(),
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
-- WINNER TRIGGER: mark chor as winner once stamped on all checkposts
-- ------------------------------------------------------------
create or replace function check_winner() returns trigger as $$
declare
  v_total int;
  v_stamped int;
  v_status text;
begin
  select count(*) into v_total from checkposts;
  select count(*) into v_stamped from checkpost_visits
    where chor_id = new.chor_id and status = 'stamped';
  select status into v_status from players where id = new.chor_id;

  if v_total > 0 and v_stamped >= v_total and v_status = 'active' then
    update players set status = 'winner' where id = new.chor_id;
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_check_winner on checkpost_visits;
create trigger trg_check_winner
  after insert or update on checkpost_visits
  for each row execute function check_winner();

-- ------------------------------------------------------------
-- RPC: finalize a scanned group at a checkpost
-- p_chor_ids: array of chor player ids scanned together
-- ------------------------------------------------------------
create or replace function finalize_checkpost_group(
  p_checkpost_id uuid,
  p_chor_ids uuid[]
) returns table (chor_id uuid, name text, status text) as $$
declare
  v_group_size int := coalesce(array_length(p_chor_ids, 1), 0);
  v_required int;
  v_status text;
begin
  if v_group_size = 0 then
    raise exception 'No chors scanned';
  end if;

  select group_size_required into v_required from game_settings where id = 1;

  if v_group_size = 1 then
    v_status := 'safe';
  elsif v_group_size = v_required then
    v_status := 'stamped';
  else
    v_status := 'vulnerable';
  end if;

  insert into checkpost_visits (chor_id, checkpost_id, status, group_size)
  select unnest(p_chor_ids), p_checkpost_id, v_status, v_group_size
  on conflict (chor_id, checkpost_id) do update
    set status = case
                    when checkpost_visits.status = 'stamped' then 'stamped'
                    else excluded.status
                  end,
        group_size = excluded.group_size,
        visited_at = now();

  return query
    select p.id, p.name, cv.status
    from players p
    join checkpost_visits cv
      on cv.chor_id = p.id and cv.checkpost_id = p_checkpost_id
    where p.id = any(p_chor_ids);
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

  insert into catches (chor_id, police_id, lifelines_after, resulted_in_elimination)
  values (p_chor_id, p_police_id, v_new_lifelines, v_eliminated);

  return query
    select p.id, p.name, p.lifelines, p.status, p.penalty_until
    from players p where p.id = p_chor_id;
end;
$$ language plpgsql security definer;

-- ------------------------------------------------------------
-- RPC: reset game (keeps players/checkposts, wipes progress)
-- ------------------------------------------------------------
create or replace function reset_game() returns void as $$
begin
  delete from catches;
  delete from checkpost_visits;
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
  count(cv.id) filter (where cv.status = 'stamped') as stamps,
  (select count(*) from checkposts) as total_checkposts
from players p
left join checkpost_visits cv on cv.chor_id = p.id
where p.role = 'chor'
group by p.id;

-- ------------------------------------------------------------
-- ROW LEVEL SECURITY
-- This is a private live-event game controlled by trusted staff,
-- so we allow the anon key full read/write access.
-- For a public deployment, tighten these policies.
-- ------------------------------------------------------------
alter table game_settings enable row level security;
alter table checkposts enable row level security;
alter table players enable row level security;
alter table checkpost_visits enable row level security;
alter table catches enable row level security;

drop policy if exists "anon_all_game_settings" on game_settings;
create policy "anon_all_game_settings" on game_settings for all using (true) with check (true);

drop policy if exists "anon_all_checkposts" on checkposts;
create policy "anon_all_checkposts" on checkposts for all using (true) with check (true);

drop policy if exists "anon_all_players" on players;
create policy "anon_all_players" on players for all using (true) with check (true);

drop policy if exists "anon_all_checkpost_visits" on checkpost_visits;
create policy "anon_all_checkpost_visits" on checkpost_visits for all using (true) with check (true);

drop policy if exists "anon_all_catches" on catches;
create policy "anon_all_catches" on catches for all using (true) with check (true);

grant usage on schema public to anon, authenticated;
grant all on all tables in schema public to anon, authenticated;
grant execute on all functions in schema public to anon, authenticated;
