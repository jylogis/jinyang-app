-- 007: 관리 권한 (특정 업체 관리 / 전체 관리)
create table if not exists public.managers (
  driver_id uuid primary key references public.drivers(id) on delete cascade,
  scope text not null check (scope in ('all','companies')),
  company_ids uuid[] not null default '{}',
  updated_at timestamptz not null default now()
);
alter table public.managers enable row level security;
create policy managers_read on public.managers for select using (driver_id = auth.uid() or public.is_admin());
create policy managers_admin on public.managers for all using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.managers to authenticated;

create or replace function public.can_manage(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (
    select 1 from public.managers m where m.driver_id = auth.uid() and (m.scope = 'all' or cid = any(m.company_ids))
  );
$$;
create or replace function public.can_manage_driver(did uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (select 1 from public.drivers d where d.id = did and public.can_manage(d.company_id));
$$;
grant execute on function public.can_manage(uuid), public.can_manage_driver(uuid) to authenticated;

-- 보안 규칙: '관리자만' → '관리자 또는 그 업체 관리 권한자'
drop policy if exists drivers_read on public.drivers;
drop policy if exists drivers_update on public.drivers;
create policy drivers_read on public.drivers for select using (id = auth.uid() or public.can_manage(company_id));
create policy drivers_update on public.drivers for update using (id = auth.uid() or public.can_manage(company_id));

drop policy if exists private_read on public.driver_private;
drop policy if exists private_update on public.driver_private;
create policy private_read on public.driver_private for select using (driver_id = auth.uid() or public.can_manage_driver(driver_id));
create policy private_update on public.driver_private for update using (driver_id = auth.uid() or public.can_manage_driver(driver_id));

drop policy if exists docs_read on public.driver_docs;
create policy docs_read on public.driver_docs for select using (driver_id = auth.uid() or public.can_manage_driver(driver_id));

drop policy if exists notices_read on public.notices;
drop policy if exists notices_admin on public.notices;
create policy notices_read on public.notices for select using (company_id = public.my_company() or public.can_manage(company_id));
create policy notices_admin on public.notices for all using (public.can_manage(company_id)) with check (public.can_manage(company_id));

drop policy if exists reads_read on public.notice_reads;
create policy reads_read on public.notice_reads for select using (driver_id = auth.uid() or public.can_manage_driver(driver_id));

drop policy if exists teams_read on public.teams_messages;
drop policy if exists teams_admin on public.teams_messages;
create policy teams_read on public.teams_messages for select using (company_id = public.my_company() or public.can_manage(company_id));
create policy teams_admin on public.teams_messages for all using (public.can_manage(company_id)) with check (public.can_manage(company_id));

drop policy if exists pay_read on public.payslips;
drop policy if exists pay_admin on public.payslips;
create policy pay_read on public.payslips for select using (driver_id = auth.uid() or public.can_manage(company_id));
create policy pay_admin on public.payslips for all using (public.can_manage(company_id)) with check (public.can_manage(company_id));

drop policy if exists reduce_read on public.reduce_requests;
drop policy if exists reduce_update on public.reduce_requests;
create policy reduce_read on public.reduce_requests for select using (driver_id = auth.uid() or public.can_manage_driver(driver_id));
create policy reduce_update on public.reduce_requests for update using (driver_id = auth.uid() or public.can_manage_driver(driver_id));

drop policy if exists lease_read on public.leases;
drop policy if exists lease_update on public.leases;
drop policy if exists lease_admin_insert on public.leases;
create policy lease_read on public.leases for select using (driver_id = auth.uid() or public.can_manage_driver(driver_id));
create policy lease_update on public.leases for update using (driver_id = auth.uid() or public.can_manage_driver(driver_id));
create policy lease_admin_insert on public.leases for insert with check (public.can_manage_driver(driver_id));

drop policy if exists routes_read on public.routes;
drop policy if exists routes_admin on public.routes;
create policy routes_read on public.routes for select using (company_id = public.my_company() or public.can_manage(company_id));
create policy routes_admin on public.routes for all using (public.can_manage(company_id)) with check (public.can_manage(company_id));

drop policy if exists dispatch_read on public.dispatches;
drop policy if exists dispatch_admin on public.dispatches;
create policy dispatch_read on public.dispatches for select using (driver_id = auth.uid() or public.can_manage(company_id));
create policy dispatch_admin on public.dispatches for all using (public.can_manage(company_id)) with check (public.can_manage(company_id));

drop policy if exists "docs own or admin read" on storage.objects;
create policy "docs own or admin read" on storage.objects for select to authenticated
  using (bucket_id = 'driver-docs' and ((storage.foldername(name))[1] = auth.uid()::text
         or public.can_manage_driver(((storage.foldername(name))[1])::uuid)));

-- 보호 규칙도 같은 기준으로 (직급 변경은 관리자만)
create or replace function public.guard_driver_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_admin() then return new; end if;
  new.id := old.id; new.rank := old.rank;
  if public.can_manage(old.company_id) then
    if not public.can_manage(new.company_id) then new.company_id := old.company_id; end if;
  else
    new.status := old.status; new.company_id := old.company_id; new.name := old.name;
  end if;
  return new;
end;
$$;

create or replace function public.guard_reduce_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage_driver(old.driver_id) then
    new.status := old.status; new.approved_at := old.approved_at; new.requested_at := old.requested_at; new.driver_id := old.driver_id;
  end if;
  return new;
end;
$$;

create or replace function public.guard_lease_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage_driver(old.driver_id) then
    if new.status <> '입금 확인 중' then new.status := old.status; end if;
    new.amount := old.amount; new.due := old.due; new.memo := old.memo; new.driver_id := old.driver_id;
  end if;
  return new;
end;
$$;

create or replace function public.guard_dispatch_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage(old.company_id) then
    new.company_id := old.company_id; new.route_id := old.route_id; new.route_name := old.route_name;
    new.driver_id := old.driver_id; new.work_date := old.work_date; new.fee := old.fee; new.memo := old.memo;
    if not public.can_clear_times() then
      if old.arrive_at is not null then new.arrive_at := old.arrive_at; end if;
      if old.pickup_at is not null then new.pickup_at := old.pickup_at; end if;
      if old.done_at is not null then new.done_at := old.done_at; end if;
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.notice_stats(p_notice uuid)
returns table(reads int, total int)
language sql stable security definer set search_path = public as $$
  select
    (select count(*)::int from public.notice_reads r where r.notice_id = p_notice),
    (select count(*)::int from public.drivers d join public.notices n on n.company_id = d.company_id
       where n.id = p_notice and d.status = '활성')
  where exists (select 1 from public.notices n where n.id = p_notice and (n.company_id = public.my_company() or public.can_manage(n.company_id)));
$$;
