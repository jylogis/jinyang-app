-- 012: 기사 면허·자격 / 차량 / 계약서 (구분별로 따로 저장)

-- 1) 면허·자격 정보
create table if not exists public.driver_licenses (
  driver_id uuid primary key references public.drivers(id) on delete cascade,
  license_type text not null default '' check (license_type in ('', '1종보통', '1종대형', '2종보통')),
  license_no text not null default '',      -- 운전면허번호 (12자리, 예: 11-23-456789-01)
  cargo_cert_no text not null default '',   -- 화물운송자격번호
  cert_date date,                           -- 자격증 취득일
  updated_at timestamptz not null default now()
);

-- 2) 차량 정보
create table if not exists public.driver_vehicles (
  driver_id uuid primary key references public.drivers(id) on delete cascade,
  car_name text not null default '',        -- 차량명 (예: 포터2)
  car_year int check (car_year is null or car_year between 1980 and 2100),  -- 연식
  car_no text not null default '',          -- 차량번호 (예: 12가3456)
  updated_at timestamptz not null default now()
);

-- 3) 계약서 (파일은 Storage 'contracts' 버킷: <기사id>/<계약서id>/파일)
create table if not exists public.driver_contracts (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.drivers(id) on delete cascade,
  title text not null default '위·수탁 계약서',
  start_date date,
  end_date date,
  memo text not null default '',
  files jsonb not null default '[]'::jsonb,  -- [{path, name, type, size}]
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists driver_contracts_driver_idx on public.driver_contracts(driver_id, created_at desc);

alter table public.driver_licenses enable row level security;
alter table public.driver_vehicles enable row level security;
alter table public.driver_contracts enable row level security;

-- 면허·차량: 본인 또는 그 기사를 관리하는 사람(관리자/관리 권한자)이 보기·입력·수정
drop policy if exists lic_read on public.driver_licenses;
drop policy if exists lic_insert on public.driver_licenses;
drop policy if exists lic_update on public.driver_licenses;
create policy lic_read on public.driver_licenses for select to authenticated using (driver_id = auth.uid() or public.can_manage_driver(driver_id));
create policy lic_insert on public.driver_licenses for insert to authenticated with check (driver_id = auth.uid() or public.can_manage_driver(driver_id));
create policy lic_update on public.driver_licenses for update to authenticated using (driver_id = auth.uid() or public.can_manage_driver(driver_id));

drop policy if exists veh_read on public.driver_vehicles;
drop policy if exists veh_insert on public.driver_vehicles;
drop policy if exists veh_update on public.driver_vehicles;
create policy veh_read on public.driver_vehicles for select to authenticated using (driver_id = auth.uid() or public.can_manage_driver(driver_id));
create policy veh_insert on public.driver_vehicles for insert to authenticated with check (driver_id = auth.uid() or public.can_manage_driver(driver_id));
create policy veh_update on public.driver_vehicles for update to authenticated using (driver_id = auth.uid() or public.can_manage_driver(driver_id));

-- 계약서: 기사는 자기 것 보기만, 등록·수정·삭제는 관리하는 사람만
drop policy if exists ctr_read on public.driver_contracts;
drop policy if exists ctr_insert on public.driver_contracts;
drop policy if exists ctr_update on public.driver_contracts;
drop policy if exists ctr_delete on public.driver_contracts;
create policy ctr_read on public.driver_contracts for select to authenticated using (driver_id = auth.uid() or public.can_manage_driver(driver_id));
create policy ctr_insert on public.driver_contracts for insert to authenticated with check (public.can_manage_driver(driver_id));
create policy ctr_update on public.driver_contracts for update to authenticated using (public.can_manage_driver(driver_id));
create policy ctr_delete on public.driver_contracts for delete to authenticated using (public.can_manage_driver(driver_id));

grant select, insert, update on public.driver_licenses, public.driver_vehicles to authenticated;
grant select, insert, update, delete on public.driver_contracts to authenticated;
grant all on public.driver_licenses, public.driver_vehicles, public.driver_contracts to service_role;

-- 4) 계약서 파일 저장소 (비공개, 파일당 20MB, PDF·사진만)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('contracts', 'contracts', false, 20971520, array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- 폴더 이름(기사 id)을 안전하게 uuid 로 바꾸기 (이상한 이름이면 null → 거부)
create or replace function public.folder_uuid(p text) returns uuid language plpgsql immutable as $$
begin return p::uuid; exception when others then return null; end $$;
grant execute on function public.folder_uuid(text) to authenticated;

drop policy if exists "contracts read" on storage.objects;
drop policy if exists "contracts upload" on storage.objects;
drop policy if exists "contracts update" on storage.objects;
drop policy if exists "contracts delete" on storage.objects;
create policy "contracts read" on storage.objects for select to authenticated
  using (bucket_id = 'contracts' and ((storage.foldername(name))[1] = auth.uid()::text or public.can_manage_driver(public.folder_uuid((storage.foldername(name))[1]))));
create policy "contracts upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'contracts' and public.can_manage_driver(public.folder_uuid((storage.foldername(name))[1])));
create policy "contracts update" on storage.objects for update to authenticated
  using (bucket_id = 'contracts' and public.can_manage_driver(public.folder_uuid((storage.foldername(name))[1])));
create policy "contracts delete" on storage.objects for delete to authenticated
  using (bucket_id = 'contracts' and public.can_manage_driver(public.folder_uuid((storage.foldername(name))[1])));

select 'ok 012' as result;
