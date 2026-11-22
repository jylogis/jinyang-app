-- 002: 직급 체계(관리자 > 총괄 > 이상 > 팀장 > 기사) + 관리자 가입 경로 정리
alter table public.drivers add column if not exists rank text not null default '기사'
  check (rank in ('총괄','이상','팀장','기사'));
alter table public.admins add column if not exists rank text not null default '관리자';

-- 기사가 직급을 스스로 바꾸지 못하게 보호
create or replace function public.guard_driver_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    new.status := old.status; new.company_id := old.company_id; new.name := old.name;
    new.id := old.id; new.rank := old.rank;
  end if;
  return new;
end;
$$;

-- 관리자 계정(admin001)을 한 번 만들 수 있게 등록 (계정 생성 직후 지움)
insert into public.admin_phones(phone) values ('admin001') on conflict do nothing;
