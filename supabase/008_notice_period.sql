-- 008: 공지 게시 기간 (기사에게는 기간 안의 공지만 보임)
alter table public.notices add column if not exists starts_at date not null default (now() at time zone 'Asia/Seoul')::date;
alter table public.notices add column if not exists ends_at date;
alter table public.notices add column if not exists updated_at timestamptz;

drop policy if exists notices_read on public.notices;
create policy notices_read on public.notices for select using (
  public.can_manage(company_id)
  or (company_id = public.my_company()
      and starts_at <= (now() at time zone 'Asia/Seoul')::date
      and (ends_at is null or ends_at >= (now() at time zone 'Asia/Seoul')::date))
);

-- 확인 인원: 모든 공지에 쓸 수 있도록 (필독 여부와 상관없이)
create or replace function public.notice_stats(p_notice uuid)
returns table(reads int, total int)
language sql stable security definer set search_path = public as $$
  select
    (select count(*)::int from public.notice_reads r where r.notice_id = p_notice),
    (select count(*)::int from public.drivers d join public.notices n on n.company_id = d.company_id
       where n.id = p_notice and d.status = '활성')
  where exists (select 1 from public.notices n where n.id = p_notice and (n.company_id = public.my_company() or public.can_manage(n.company_id)));
$$;
