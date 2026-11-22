-- 011: 알림 발송 기록 (공지·시험 알림을 언제, 누구에게, 몇 대 보냈는지)
create table if not exists public.push_logs (
  id uuid primary key default gen_random_uuid(),
  kind text not null,                 -- notice | test
  notice_id uuid references public.notices(id) on delete set null,
  company_id uuid references public.companies(id) on delete set null,
  title text not null default '',
  sent_by uuid references auth.users(id) on delete set null,
  drivers int not null default 0,     -- 대상 기사 수
  devices int not null default 0,     -- 등록된 폰 수
  sent int not null default 0,        -- 성공
  removed int not null default 0,     -- 무효 등록 정리
  skipped text,                       -- 안 보낸 이유 (알림 꺼짐, 게시 기간 아님 등)
  errors jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists push_logs_created_idx on public.push_logs(created_at desc);
alter table public.push_logs enable row level security;
drop policy if exists push_logs_admin_read on public.push_logs;
create policy push_logs_admin_read on public.push_logs for select to authenticated using (public.is_admin());
grant select on public.push_logs to authenticated;
grant all on public.push_logs to service_role;
select 'ok 011' as result;
