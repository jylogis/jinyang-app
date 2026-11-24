-- 013: 미배정 배차 '배정 신청' (기사 → 관리자·배차 수정 권한자)

-- 1) 배정 신청 기록 (따로 저장)
create table if not exists public.dispatch_requests (
  id uuid primary key default gen_random_uuid(),
  dispatch_id uuid not null references public.dispatches(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  driver_id uuid not null references public.drivers(id) on delete cascade,
  driver_name text not null default '',     -- 신청 당시 이름·직급 (권한자가 기사 목록을 못 봐도 표시되게)
  driver_rank text not null default '',
  status text not null default '대기' check (status in ('대기', '배정', '반려', '취소')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references auth.users(id) on delete set null,
  unique (dispatch_id, driver_id)
);
create index if not exists dispatch_requests_dispatch_idx on public.dispatch_requests(dispatch_id);
alter table public.dispatch_requests enable row level security;

-- 배차 '수정' 권한이 있는 사람 (관리자·관리 권한자, 또는 같은 업체에서 탭 관리상 배차 수정 권한이 있는 직급)
create or replace function public.can_assign_dispatch(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.can_manage(cid) or (public.my_company() = cid and public.tab_can('dispatch', 'edit'));
$$;
grant execute on function public.can_assign_dispatch(uuid) to authenticated;

drop policy if exists dreq_read on public.dispatch_requests;
create policy dreq_read on public.dispatch_requests for select to authenticated
  using (driver_id = auth.uid() or public.can_assign_dispatch(company_id));
grant select on public.dispatch_requests to authenticated;
grant all on public.dispatch_requests to service_role;

-- 2) 기사는 '자기 업체의 미배정 배차'를 볼 수 있음 (승인된 기사만)
drop policy if exists dispatch_open_read on public.dispatches;
create policy dispatch_open_read on public.dispatches for select to authenticated
  using (driver_id is null and company_id = public.my_company()
         and exists (select 1 from public.drivers d where d.id = auth.uid() and d.status = '활성'));
-- 배차 수정 권한 직급은 자기 업체 배차를 모두 볼 수 있음 (신청 승인용)
drop policy if exists dispatch_editor_read on public.dispatches;
create policy dispatch_editor_read on public.dispatches for select to authenticated
  using (public.can_assign_dispatch(company_id));

-- 3) 배정 신청 / 취소 / 배정 (한 번에 안전하게 처리하는 함수)
create or replace function public.request_dispatch(p_dispatch uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare d public.dispatches; me public.drivers; rid uuid;
begin
  select * into me from public.drivers where id = auth.uid();
  if me.id is null or me.status <> '활성' then raise exception '승인된 기사만 신청할 수 있어요'; end if;
  select * into d from public.dispatches where id = p_dispatch for update;
  if d.id is null or d.company_id <> me.company_id then raise exception '신청할 수 없는 배차예요'; end if;
  if d.driver_id is not null then raise exception '이미 배정된 배차예요'; end if;
  if d.work_date < (now() at time zone 'Asia/Seoul')::date then raise exception '지난 날짜 배차는 신청할 수 없어요'; end if;
  insert into public.dispatch_requests(dispatch_id, company_id, driver_id, driver_name, driver_rank)
  values (d.id, d.company_id, me.id, me.name, coalesce(me.rank, '기사'))
  on conflict (dispatch_id, driver_id) do update set status = '대기', created_at = now(), decided_at = null, decided_by = null,
    driver_name = excluded.driver_name, driver_rank = excluded.driver_rank
  returning id into rid;
  return rid;
end $$;

create or replace function public.cancel_dispatch_request(p_req uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.dispatch_requests set status = '취소', decided_at = now()
  where id = p_req and driver_id = auth.uid() and status = '대기';
  if not found then raise exception '취소할 수 있는 신청이 없어요'; end if;
end $$;

create or replace function public.assign_dispatch(p_req uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r public.dispatch_requests; d public.dispatches;
begin
  select * into r from public.dispatch_requests where id = p_req;
  if r.id is null then raise exception '신청을 찾을 수 없어요'; end if;
  if not public.can_assign_dispatch(r.company_id) then raise exception '배정 권한이 없어요'; end if;
  select * into d from public.dispatches where id = r.dispatch_id for update;
  if d.driver_id is not null then raise exception '이미 다른 기사가 배정됐어요'; end if;
  if r.status <> '대기' then raise exception '대기 중인 신청이 아니에요'; end if;
  perform set_config('jy.assign', 'on', true);   -- 아래 보호 장치에 '정식 배정'이라고 알림
  update public.dispatches set driver_id = r.driver_id where id = d.id;
  update public.dispatch_requests set decided_by = auth.uid() where id = r.id;
end $$;

grant execute on function public.request_dispatch(uuid), public.cancel_dispatch_request(uuid), public.assign_dispatch(uuid) to authenticated;

-- 4) 배차 보호 장치: 관리 권한 없는 사람은 배정·노선 등 못 바꿈 (단, 위 '정식 배정' 함수는 허용)
create or replace function public.guard_dispatch_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage(old.company_id) then
    new.company_id := old.company_id; new.route_id := old.route_id; new.route_name := old.route_name;
    new.work_date := old.work_date; new.fee := old.fee; new.memo := old.memo;
    if not (coalesce(current_setting('jy.assign', true), '') = 'on' and old.driver_id is null) then
      new.driver_id := old.driver_id;
    end if;
    if not public.can_clear_times() then
      if old.arrive_at is not null then new.arrive_at := old.arrive_at; end if;
      if old.pickup_at is not null then new.pickup_at := old.pickup_at; end if;
      if old.done_at is not null then new.done_at := old.done_at; end if;
    end if;
  end if;
  return new;
end;
$$;

-- 5) 배차에 기사가 정해지면(신청 승인이든, 관리자가 직접 고르든) 신청 상태 자동 정리
create or replace function public.settle_dispatch_requests() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.driver_id is distinct from old.driver_id then
    if new.driver_id is not null then
      update public.dispatch_requests set status = case when driver_id = new.driver_id then '배정' else '반려' end,
        decided_at = now(), decided_by = coalesce(decided_by, auth.uid())
      where dispatch_id = new.id and status = '대기';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists settle_dispatch_requests on public.dispatches;
create trigger settle_dispatch_requests after update of driver_id on public.dispatches
  for each row execute function public.settle_dispatch_requests();

select 'ok 013' as result;
