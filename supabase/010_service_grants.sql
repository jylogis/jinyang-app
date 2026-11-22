-- 010: 서버(Edge Function) 전용 권한 — service_role 만 (앱 사용자 권한은 그대로)
grant usage on schema public to service_role;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;
alter default privileges in schema public grant all on tables to service_role;
select 'ok 010' as result;
