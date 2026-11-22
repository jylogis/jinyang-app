-- 005: 직급별 권한 (배차 시간 '기록 취소') + 기사가 이미 기록된 시간을 덮어쓰지 못하게
create table if not exists public.rank_perms (
  rank text primary key check (rank in ('총괄','이상','팀장','기사')),
  can_clear_times boolean not null default false
);
insert into public.rank_perms(rank, can_clear_times) values ('총괄', false), ('이상', false), ('팀장', false), ('기사', false)
on conflict (rank) do nothing;

alter table public.rank_perms enable row level security;
create policy rank_perms_read on public.rank_perms for select to authenticated using (true);
create policy rank_perms_admin on public.rank_perms for all using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.rank_perms to authenticated;

create or replace function public.can_clear_times() returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (
    select 1 from public.drivers d join public.rank_perms p on p.rank = d.rank
    where d.id = auth.uid() and p.can_clear_times
  );
$$;
grant execute on function public.can_clear_times() to authenticated;

create or replace function public.guard_dispatch_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    new.company_id := old.company_id; new.route_id := old.route_id; new.route_name := old.route_name;
    new.driver_id := old.driver_id; new.work_date := old.work_date; new.fee := old.fee; new.memo := old.memo;
    -- 권한 없는 직급은 이미 기록된 시간을 지우거나 바꿀 수 없음
    if not public.can_clear_times() then
      if old.arrive_at is not null then new.arrive_at := old.arrive_at; end if;
      if old.pickup_at is not null then new.pickup_at := old.pickup_at; end if;
      if old.done_at is not null then new.done_at := old.done_at; end if;
    end if;
  end if;
  return new;
end;
$$;
