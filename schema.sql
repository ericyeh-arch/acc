-- 請購系統 schema(貼到 Supabase SQL Editor 執行)
-- 另需:Authentication → Providers → Email 啟用,並關閉 "Allow new users to sign up"(帳號由管理員建立)

-- 使用者資料(對應 auth.users)
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '',
  role text not null default 'user' check (role in ('user','admin')),
  created_at timestamptz not null default now()
);

-- 註冊時自動建立 profile(role 一律 user,不信任前端傳入)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)));
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin()
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- 請購單
create table if not exists public.purchase_requests (
  id bigint generated always as identity primary key,
  case_no text not null unique,                       -- 購案編號
  amount numeric(12,0) not null check (amount >= 0),  -- 金額
  item text not null default '',                      -- 品名/用途
  sent_date date not null default current_date,       -- 送出日期
  status text not null default '已核准'
    check (status in ('待送出','已送出','已核准','已駁回')),
  created_by uuid not null default auth.uid() references public.profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists purchase_requests_created_by_idx on public.purchase_requests(created_by);

alter table public.profiles enable row level security;
alter table public.purchase_requests enable row level security;

-- profiles:本人或管理員可讀;不開放前端修改(升管理員請用 SQL)
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select
  using (id = auth.uid() or public.is_admin());

-- purchase_requests
drop policy if exists pr_select on public.purchase_requests;
create policy pr_select on public.purchase_requests for select
  using (created_by = auth.uid() or public.is_admin());

drop policy if exists pr_insert on public.purchase_requests;
create policy pr_insert on public.purchase_requests for insert
  with check (created_by = auth.uid() and status = '已核准');

-- 輸入完成即核准:使用者可修改自己的單(狀態固定為已核准)
drop policy if exists pr_update_own on public.purchase_requests;
create policy pr_update_own on public.purchase_requests for update
  using (created_by = auth.uid())
  with check (created_by = auth.uid() and status = '已核准');

drop policy if exists pr_update_admin on public.purchase_requests;
create policy pr_update_admin on public.purchase_requests for update
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists pr_delete_own on public.purchase_requests;
create policy pr_delete_own on public.purchase_requests for delete
  using (created_by = auth.uid() or public.is_admin());

-- 設定管理員(把 email 換成你的):
-- update public.profiles set role = 'admin'
--   where id = (select id from auth.users where email = 'you@example.com');

-- 表的存取權限(此專案不會自動授權給 authenticated;實際資料範圍由上面的 RLS 控制)
grant usage on schema public to authenticated;
grant select on public.profiles to authenticated;
grant select, insert, update, delete on public.purchase_requests to authenticated;

-- 公開進度查詢(免登入):只能用「完整購案編號」查,且只回傳編號、狀態、送出日期
create or replace function public.track_request(p_case_no text)
returns table(case_no text, status text, sent_date date)
language sql security definer stable set search_path = public as $$
  select r.case_no, r.status, r.sent_date from public.purchase_requests r
  where upper(r.case_no) = upper(trim(p_case_no)) limit 1;
$$;
revoke all on function public.track_request(text) from public;
grant execute on function public.track_request(text) to anon, authenticated;

-- 既有資料庫升級(「輸入完成即核准」):若表已存在請執行
alter table public.purchase_requests alter column status set default '已核准';
update public.purchase_requests set sent_date = coalesce(sent_date, created_at::date) where sent_date is null;
alter table public.purchase_requests alter column sent_date set default current_date;
alter table public.purchase_requests alter column sent_date set not null;
update public.purchase_requests set status = '已核准' where status <> '已核准';
