-- =========================================================
-- 진양로지스틱스 기사앱 · Supabase 스키마 (1차)
-- 기사는 본인 정보만, 관리자는 모든 업체 정보를 보고 관리
-- =========================================================

-- 업체(소속센터)
create table if not exists public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  camp text not null default '',
  teams_room text not null default '',
  created_at timestamptz not null default now()
);

-- 관리자로 가입시킬 전화번호 목록
create table if not exists public.admin_phones (
  phone text primary key
);

-- 관리자 계정
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '관리자',
  phone text not null default '',
  created_at timestamptz not null default now()
);

-- 기사 기본 정보
create table if not exists public.drivers (
  id uuid primary key references auth.users(id) on delete cascade,
  company_id uuid references public.companies(id),
  name text not null,
  phone text not null,
  sub_phone text not null default '',
  address text not null default '',
  status text not null default '승인 대기' check (status in ('승인 대기','활성')),
  created_at timestamptz not null default now()
);

-- 주민등록번호 (따로 분리 보관)
create table if not exists public.driver_private (
  driver_id uuid primary key references public.drivers(id) on delete cascade,
  rrn text not null,
  updated_at timestamptz not null default now()
);

-- 서류 사진 (파일은 Storage 'driver-docs' 버킷에 저장)
create table if not exists public.driver_docs (
  driver_id uuid not null references public.drivers(id) on delete cascade,
  kind text not null check (kind in ('license','cargo','car','biz')),
  path text not null,
  uploaded_at timestamptz not null default now(),
  primary key (driver_id, kind)
);

-- 공지사항
create table if not exists public.notices (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  tag text not null default '일반',
  title text not null,
  body text not null default '',
  must boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.notice_reads (
  notice_id uuid not null references public.notices(id) on delete cascade,
  driver_id uuid not null references public.drivers(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (notice_id, driver_id)
);

-- 팀즈 감지 메시지
create table if not exists public.teams_messages (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  keyword text not null default '',
  message text not null,
  hot boolean not null default false,
  created_at timestamptz not null default now()
);

-- 정산서
create table if not exists public.payslips (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.drivers(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  month text not null,              -- 예: '2026-11'
  period text not null default '',  -- 예: '10/26 ~ 11/25'
  total bigint not null default 0,  -- 실지급액
  items jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  unique (driver_id, month)
);

-- 감차 요청 (의무근무 60일은 승인일부터)
create table if not exists public.reduce_requests (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.drivers(id) on delete cascade,
  company_id uuid references public.companies(id),
  requested_at date not null default (now() at time zone 'Asia/Seoul')::date,
  status text not null default '요청' check (status in ('요청','승인','반려')),
  approved_at date,
  ack boolean not null default false,
  created_at timestamptz not null default now()
);

-- 넘버 임대료
create table if not exists public.leases (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.drivers(id) on delete cascade,
  company_id uuid references public.companies(id),
  amount bigint not null check (amount > 0),
  due date not null,
  memo text not null default '',
  status text not null default '납부 대기' check (status in ('납부 대기','입금 확인 중','납부 완료')),
  created_at timestamptz not null default now()
);

-- ---------- 도우미 함수 ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

create or replace function public.my_company() returns uuid
language sql stable security definer set search_path = public as $$
  select company_id from public.drivers where id = auth.uid();
$$;

-- 공지 확인 인원 (기사는 다른 기사 정보를 못 보므로 숫자만 돌려줌)
create or replace function public.notice_stats(p_notice uuid)
returns table(reads int, total int)
language sql stable security definer set search_path = public as $$
  select
    (select count(*)::int from public.notice_reads r where r.notice_id = p_notice),
    (select count(*)::int from public.drivers d join public.notices n on n.company_id = d.company_id
       where n.id = p_notice and d.status = '활성')
  where public.is_admin()
     or exists (select 1 from public.notices n where n.id = p_notice and n.company_id = public.my_company());
$$;

-- 가입 시 자동 처리: 관리자 번호면 관리자, 아니면 기사(승인 대기)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  ph text := coalesce(m->>'phone', '');
begin
  if exists (select 1 from public.admin_phones where phone = ph) then
    insert into public.admins(user_id, name, phone) values (new.id, coalesce(nullif(m->>'name',''), '관리자'), ph)
    on conflict do nothing;
  else
    insert into public.drivers(id, company_id, name, phone, sub_phone, address)
    values (new.id, nullif(m->>'company_id','')::uuid, coalesce(m->>'name',''), ph,
            coalesce(m->>'sub_phone',''), coalesce(m->>'address',''))
    on conflict do nothing;
  end if;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 기사가 직접 바꾸면 안 되는 값 보호
create or replace function public.guard_driver_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    new.status := old.status; new.company_id := old.company_id; new.name := old.name; new.id := old.id;
  end if;
  return new;
end;
$$;
drop trigger if exists guard_driver_update on public.drivers;
create trigger guard_driver_update before update on public.drivers
  for each row execute function public.guard_driver_update();

create or replace function public.guard_reduce_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    new.status := old.status; new.approved_at := old.approved_at; new.requested_at := old.requested_at;
    new.driver_id := old.driver_id;
  end if;
  return new;
end;
$$;
drop trigger if exists guard_reduce_update on public.reduce_requests;
create trigger guard_reduce_update before update on public.reduce_requests
  for each row execute function public.guard_reduce_update();

create or replace function public.guard_lease_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    if new.status <> '입금 확인 중' then new.status := old.status; end if;
    new.amount := old.amount; new.due := old.due; new.memo := old.memo; new.driver_id := old.driver_id;
  end if;
  return new;
end;
$$;
drop trigger if exists guard_lease_update on public.leases;
create trigger guard_lease_update before update on public.leases
  for each row execute function public.guard_lease_update();

-- ---------- 보안 규칙 (RLS) ----------
alter table public.companies enable row level security;
alter table public.admin_phones enable row level security;
alter table public.admins enable row level security;
alter table public.drivers enable row level security;
alter table public.driver_private enable row level security;
alter table public.driver_docs enable row level security;
alter table public.notices enable row level security;
alter table public.notice_reads enable row level security;
alter table public.teams_messages enable row level security;
alter table public.payslips enable row level security;
alter table public.reduce_requests enable row level security;
alter table public.leases enable row level security;

-- 업체 이름은 가입 화면에서 골라야 하므로 누구나 조회
create policy companies_read on public.companies for select using (true);
create policy companies_admin on public.companies for all using (public.is_admin()) with check (public.is_admin());

create policy admins_self on public.admins for select using (user_id = auth.uid() or public.is_admin());

create policy drivers_read on public.drivers for select using (id = auth.uid() or public.is_admin());
create policy drivers_update on public.drivers for update using (id = auth.uid() or public.is_admin());

create policy private_read on public.driver_private for select using (driver_id = auth.uid() or public.is_admin());
create policy private_insert on public.driver_private for insert with check (driver_id = auth.uid());
create policy private_update on public.driver_private for update using (driver_id = auth.uid() or public.is_admin());

create policy docs_read on public.driver_docs for select using (driver_id = auth.uid() or public.is_admin());
create policy docs_write on public.driver_docs for insert with check (driver_id = auth.uid());
create policy docs_update on public.driver_docs for update using (driver_id = auth.uid());

create policy notices_read on public.notices for select using (company_id = public.my_company() or public.is_admin());
create policy notices_admin on public.notices for all using (public.is_admin()) with check (public.is_admin());

create policy reads_read on public.notice_reads for select using (driver_id = auth.uid() or public.is_admin());
create policy reads_insert on public.notice_reads for insert with check (driver_id = auth.uid());

create policy teams_read on public.teams_messages for select using (company_id = public.my_company() or public.is_admin());
create policy teams_admin on public.teams_messages for all using (public.is_admin()) with check (public.is_admin());

create policy pay_read on public.payslips for select using (driver_id = auth.uid() or public.is_admin());
create policy pay_admin on public.payslips for all using (public.is_admin()) with check (public.is_admin());

create policy reduce_read on public.reduce_requests for select using (driver_id = auth.uid() or public.is_admin());
create policy reduce_insert on public.reduce_requests for insert with check (driver_id = auth.uid());
create policy reduce_update on public.reduce_requests for update using (driver_id = auth.uid() or public.is_admin());

create policy lease_read on public.leases for select using (driver_id = auth.uid() or public.is_admin());
create policy lease_update on public.leases for update using (driver_id = auth.uid() or public.is_admin());
create policy lease_admin_insert on public.leases for insert with check (public.is_admin());

-- ---------- 서류 사진 저장소 (비공개) ----------
insert into storage.buckets (id, name, public) values ('driver-docs', 'driver-docs', false)
on conflict (id) do nothing;

create policy "docs own upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'driver-docs' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "docs own update" on storage.objects for update to authenticated
  using (bucket_id = 'driver-docs' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "docs own or admin read" on storage.objects for select to authenticated
  using (bucket_id = 'driver-docs' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- ---------- 기본 업체 ----------
insert into public.companies(name, camp, teams_room) values ('진양로지스틱스', '[캠프명]', '[캠프명] Teams방')
on conflict (name) do nothing;

-- ---------- 앱(Data API)에서 테이블을 쓸 수 있게 권한 부여 (실제 범위는 위 RLS 규칙이 제한) ----------
grant usage on schema public to anon, authenticated;
grant select on public.companies to anon;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant execute on function public.is_admin(), public.my_company(), public.notice_stats(uuid) to authenticated;

-- ---------- 관리자 가입 화면에서 '등록된 관리자 번호인지'만 확인 ----------
create or replace function public.is_admin_phone(p_phone text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admin_phones where phone = p_phone);
$$;
grant execute on function public.is_admin_phone(text) to anon, authenticated;
