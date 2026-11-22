-- 004: 노선 설정 + 배차
create table if not exists public.routes (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  fee bigint not null default 0 check (fee >= 0),   -- 기본 배송료
  memo text not null default '',
  sort int not null default 0,
  created_at timestamptz not null default now(),
  unique (company_id, name)
);

create table if not exists public.dispatches (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  route_id uuid references public.routes(id) on delete set null,
  route_name text not null,                          -- 노선이 지워져도 기록은 남도록 이름 보관
  driver_id uuid references public.drivers(id) on delete set null,
  work_date date not null default (now() at time zone 'Asia/Seoul')::date,
  arrive_at timestamptz,                             -- 입차 시간
  pickup_at timestamptz,                             -- 픽업 시간
  done_at timestamptz,                               -- 완료 시간
  fee bigint not null default 0 check (fee >= 0),    -- 배송료
  memo text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists dispatches_company_date on public.dispatches(company_id, work_date);
create index if not exists dispatches_driver_date on public.dispatches(driver_id, work_date);

-- 기사는 자기 배차의 시간 기록(입차·픽업·완료)만 바꿀 수 있음
create or replace function public.guard_dispatch_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    new.company_id := old.company_id; new.route_id := old.route_id; new.route_name := old.route_name;
    new.driver_id := old.driver_id; new.work_date := old.work_date; new.fee := old.fee; new.memo := old.memo;
  end if;
  return new;
end;
$$;
drop trigger if exists guard_dispatch_update on public.dispatches;
create trigger guard_dispatch_update before update on public.dispatches
  for each row execute function public.guard_dispatch_update();

alter table public.routes enable row level security;
alter table public.dispatches enable row level security;

create policy routes_read on public.routes for select using (company_id = public.my_company() or public.is_admin());
create policy routes_admin on public.routes for all using (public.is_admin()) with check (public.is_admin());

create policy dispatch_read on public.dispatches for select using (driver_id = auth.uid() or public.is_admin());
create policy dispatch_admin on public.dispatches for all using (public.is_admin()) with check (public.is_admin());
create policy dispatch_driver_time on public.dispatches for update using (driver_id = auth.uid());

grant select, insert, update, delete on public.routes, public.dispatches to authenticated;
