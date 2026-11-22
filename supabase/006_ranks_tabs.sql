-- 006: 직급 정리(관리자 · 총괄 · 이사 · 팀장 · 조장 · 기사) + 탭별 활성화·알림·권한
alter table public.drivers drop constraint if exists drivers_rank_check;
update public.drivers set rank = '이사' where rank = '이상';
alter table public.drivers add constraint drivers_rank_check check (rank in ('총괄','이사','팀장','조장','기사'));

alter table public.rank_perms drop constraint if exists rank_perms_rank_check;
update public.rank_perms set rank = '이사' where rank = '이상';
alter table public.rank_perms add constraint rank_perms_rank_check check (rank in ('총괄','이사','팀장','조장','기사'));
insert into public.rank_perms(rank, can_clear_times) values ('조장', false) on conflict (rank) do nothing;

-- 탭 설정: 활성화, 알림, 직급별 {보기, 수정}
create table if not exists public.tab_settings (
  tab text primary key,
  enabled boolean not null default true,
  notify boolean not null default true,
  perms jsonb not null default '{}'::jsonb,
  sort int not null default 0
);
insert into public.tab_settings(tab, enabled, notify, perms, sort) values
 ('notice',   true, true,  '{"총괄":{"view":true,"edit":true},"이사":{"view":true,"edit":true},"팀장":{"view":true,"edit":false},"조장":{"view":true,"edit":false},"기사":{"view":true,"edit":false}}', 1),
 ('dispatch', true, true,  '{"총괄":{"view":true,"edit":false},"이사":{"view":true,"edit":false},"팀장":{"view":true,"edit":false},"조장":{"view":true,"edit":false},"기사":{"view":true,"edit":false}}', 2),
 ('pay',      true, true,  '{"총괄":{"view":true,"edit":false},"이사":{"view":true,"edit":false},"팀장":{"view":true,"edit":false},"조장":{"view":true,"edit":false},"기사":{"view":true,"edit":false}}', 3),
 ('teams',    true, false, '{"총괄":{"view":false,"edit":false},"이사":{"view":false,"edit":false},"팀장":{"view":false,"edit":false},"조장":{"view":false,"edit":false},"기사":{"view":false,"edit":false}}', 4),
 ('me',       true, true,  '{"총괄":{"view":true,"edit":false},"이사":{"view":true,"edit":false},"팀장":{"view":true,"edit":false},"조장":{"view":true,"edit":false},"기사":{"view":true,"edit":false}}', 5)
on conflict (tab) do nothing;

alter table public.tab_settings enable row level security;
create policy tab_settings_read on public.tab_settings for select to authenticated using (true);
create policy tab_settings_admin on public.tab_settings for all using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.tab_settings to authenticated;

-- 이 사람이 이 탭에서 보기/수정 권한이 있는지 (관리자는 항상 true)
create or replace function public.tab_can(p_tab text, p_kind text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (
    select 1 from public.tab_settings t join public.drivers d on d.id = auth.uid()
    where t.tab = p_tab and t.enabled and coalesce((t.perms -> d.rank ->> p_kind)::boolean, false)
  );
$$;
grant execute on function public.tab_can(text, text) to authenticated;

-- 공지 '수정' 권한이 있는 직급은 자기 업체 공지를 쓸 수 있음
create policy notices_rank_insert on public.notices for insert
  with check (company_id = public.my_company() and public.tab_can('notice', 'edit'));
