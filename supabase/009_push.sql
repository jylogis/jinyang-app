-- 009: 웹 푸시 알림 (기기 구독 저장 + 서버 전용 비밀값 보관)

-- 서버(Edge Function)만 읽고 쓰는 비밀값 보관함. 앱(기사/관리자)은 접근 불가
create table if not exists public.app_secrets (
  k text primary key,
  v text not null,
  created_at timestamptz not null default now()
);
alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from anon, authenticated;

-- 기기별 알림 구독 (폰 1대 = 1행)
create table if not exists public.push_subs (
  endpoint text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  p256dh text not null,
  auth text not null,
  ua text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists push_subs_user_idx on public.push_subs(user_id);
alter table public.push_subs enable row level security;
drop policy if exists push_subs_own_read on public.push_subs;
create policy push_subs_own_read on public.push_subs for select to authenticated using (user_id = auth.uid());
drop policy if exists push_subs_own_del on public.push_subs;
create policy push_subs_own_del on public.push_subs for delete to authenticated using (user_id = auth.uid());
grant select, delete on public.push_subs to authenticated;

-- 구독 저장: 같은 폰에서 다른 계정으로 로그인하면 그 계정으로 옮겨줌
create or replace function public.save_push_sub(p_endpoint text, p_p256dh text, p_auth text, p_ua text default '')
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not logged in'; end if;
  insert into public.push_subs(endpoint, user_id, p256dh, auth, ua)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth, coalesce(p_ua, ''))
  on conflict (endpoint) do update
    set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth, ua = excluded.ua, updated_at = now();
end $$;
revoke all on function public.save_push_sub(text, text, text, text) from public, anon;
grant execute on function public.save_push_sub(text, text, text, text) to authenticated;

select 'ok 009' as result;
