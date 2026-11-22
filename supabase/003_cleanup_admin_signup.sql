-- 003: 관리자 가입 화면 삭제에 맞춰 가입 경로 닫기
delete from public.admin_phones;
drop function if exists public.is_admin_phone(text);
