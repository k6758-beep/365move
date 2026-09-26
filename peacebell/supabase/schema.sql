-- ════════════════════════════════════════════════════════════════
--  厝邊平安鈴 v2 ─ Supabase 資料庫
--  用法：Supabase 後台 → SQL Editor → New query → 整份貼上 → Run
--  可以重複執行（會覆蓋函式，不會刪資料）
-- ════════════════════════════════════════════════════════════════

create extension if not exists pg_cron;
create extension if not exists pg_net;

create schema if not exists private;          -- 不對外開放的內部區
revoke all on schema private from public;

-- ───────────── 1. 設定 ─────────────
create table if not exists public.settings(
  id               int  primary key default 1 check (id = 1),
  village          text not null default '',
  backup_after_min int  not null default 30 check (backup_after_min between 5 and 600),
  chief_after_min  int  not null default 60 check (chief_after_min between 10 and 1440)
);
insert into public.settings(id) values (1) on conflict do nothing;

create table if not exists private.config(key text primary key, value text);

-- ───────────── 2. 人員（志工／里長／社工／管理者）─────────────
create table if not exists public.profiles(
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text not null default '',
  phone      text not null default '',
  role       text not null default 'volunteer' check (role in ('volunteer','chief','social','admin')),
  active     boolean not null default false,          -- 新帳號要管理者開通
  created_at timestamptz not null default now()
);

create or replace function public.on_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, name)
  values (new.id, split_part(coalesce(new.email, ''), '@', 1))
  on conflict do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.on_new_user();

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and active);
$$;
create or replace function public.is_manager() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and active and role in ('chief','social','admin'));
$$;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and active and role = 'admin');
$$;

-- ───────────── 3. 長輩 ─────────────
-- 專屬代碼：8 碼，排除 0/O/1/I 等易混字元（32^8 ≈ 1.1 兆種組合）
create or replace function public.new_token() returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  a   constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  idx constant int[] := array[0,1,2,3,4,5,7,9];      -- 避開 UUID 固定位元
  b bytea; r text; i int;
begin
  loop
    b := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    r := '';
    foreach i in array idx loop
      r := r || substr(a, (get_byte(b, i) % 32) + 1, 1);
    end loop;
    exit when not exists (select 1 from public.elders where token = r);
  end loop;
  return r;
end $$;

create table if not exists public.elders(
  id           uuid primary key default gen_random_uuid(),
  token        text unique not null default public.new_token(),
  name         text not null check (length(name) between 1 and 16),
  mode         text not null default 'self' check (mode in ('self','call')),  -- self 自己按／call 志工打電話
  deadline     time not null default '10:00',
  phone        text not null default '',
  family_name  text not null default '',
  family_phone text not null default '',
  primary_vol  uuid references public.profiles(id) on delete set null,
  backup_vol   uuid references public.profiles(id) on delete set null,
  note         text not null default '',
  consent      boolean not null default false,
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

-- ───────────── 4. 每日回報 ─────────────
create table if not exists public.checkins(
  id       bigint generated always as identity primary key,
  elder_id uuid not null references public.elders(id) on delete cascade,
  day      date not null,                          -- 台灣日期
  kind     text not null check (kind in ('ok','call','help')),
  at       timestamptz not null default now(),
  source   text not null default 'elder' check (source in ('elder','volunteer')),
  by_user  uuid references public.profiles(id) on delete set null,
  note     text not null default ''
);
create index if not exists checkins_elder_day on public.checkins(elder_id, day);

-- ───────────── 5. 關懷個案（一位長輩一天一案）─────────────
-- stage：1 尚未回報 2 第一次聯絡未接 3 第二次聯絡未接 4 已通知家屬 5 已通知里長／社工 6 已確認安全／結案
-- level：1 主責志工 2 已轉交備援 3 已通報里長／社工（系統自動升級）
create table if not exists public.cases(
  id               uuid primary key default gen_random_uuid(),
  elder_id         uuid not null references public.elders(id) on delete cascade,
  day              date not null,
  reason           text not null check (reason in ('overdue','help')),
  stage            int  not null default 1 check (stage between 1 and 6),
  level            int  not null default 1 check (level between 1 and 3),
  need_help        boolean not null default false,
  opened_at        timestamptz not null default now(),
  last_human_at    timestamptz,
  level_changed_at timestamptz not null default now(),
  closed_at        timestamptz,
  closed_by        uuid references public.profiles(id) on delete set null,
  unique (elder_id, day)
);

create table if not exists public.case_events(
  id      bigint generated always as identity primary key,
  case_id uuid not null references public.cases(id) on delete cascade,
  at      timestamptz not null default now(),
  actor   uuid references public.profiles(id) on delete set null,   -- 空白＝系統
  action  text not null,
  stage   int,
  note    text not null default ''
);
create index if not exists case_events_case on public.case_events(case_id, at);

-- ───────────── 6. 推播 ─────────────
create table if not exists public.push_subscriptions(
  endpoint   text primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  ua         text not null default '',
  created_at timestamptz not null default now()
);
create table if not exists private.notifications(
  id         bigint generated always as identity primary key,
  user_id    uuid not null,
  title      text not null,
  body       text not null default '',
  url        text not null default 'care.html',
  tag        text not null default '',
  created_at timestamptz not null default now(),
  sent_at    timestamptz
);

-- ════════════════ 內部計算 ════════════════
-- 「自己回報」的平安：自己按的長輩只算長輩本人按的；志工問安的長輩算志工的紀錄
create or replace view private.v_ok as
  select k.elder_id, k.day, min(k.at) as ok_at
  from public.checkins k join public.elders e on e.id = k.elder_id
  where k.kind in ('ok','call') and (e.mode = 'call' or k.source = 'elder')
  group by k.elder_id, k.day;

-- 某一天的狀態：ok 準時／late 遲到／help 求助／checked 未自行回報但志工確認平安／miss 未回報／wait 還沒到時間／none 尚未加入
create or replace function private.day_status(p_elder uuid, p_day date) returns text
language plpgsql stable security definer set search_path = public, private as $$
declare
  e record; ok timestamptz;
  now_tw timestamp := now() at time zone 'Asia/Taipei';
begin
  select deadline, created_at at time zone 'Asia/Taipei' as c0 into e from elders where id = p_elder;
  if e is null or p_day < e.c0::date or p_day > now_tw::date then return 'none'; end if;
  if exists(select 1 from checkins where elder_id = p_elder and day = p_day and kind = 'help')
     or exists(select 1 from cases where elder_id = p_elder and day = p_day and (reason = 'help' or need_help)) then
    return 'help';
  end if;
  select ok_at into ok from v_ok where elder_id = p_elder and day = p_day;
  if ok is not null then
    return case when (ok at time zone 'Asia/Taipei')::time <= e.deadline then 'ok' else 'late' end;
  end if;
  if exists(select 1 from checkins where elder_id = p_elder and day = p_day and kind in ('ok','call')) then
    return 'checked';
  end if;
  if p_day = e.c0::date and e.c0::time > e.deadline then return 'none'; end if;  -- 過了時間才加入的第一天
  if p_day = now_tw::date and now_tw::time < e.deadline then return 'wait'; end if;
  return 'miss';
end $$;

-- 連續自行回報天數
create or replace function private.streak(p_elder uuid) returns int
language sql stable security definer set search_path = public, private as $$
  with t as (select (now() at time zone 'Asia/Taipei')::date as today),
  s as (select case when exists(select 1 from private.v_ok o, t where o.elder_id = p_elder and o.day = t.today)
                    then t.today else t.today - 1 end as start from t),
  d as (select (s.start - o.day) as off, row_number() over (order by o.day desc) - 1 as rn
        from private.v_ok o, s where o.elder_id = p_elder and o.day <= s.start)
  select count(*)::int from d where off = rn;
$$;

-- 推播排程：1 主責（沒有就找里長社工）、2 備援（沒有就找里長社工）、3 里長／社工／管理者
create or replace function private.notify_level(p_elder uuid, p_level int, p_title text, p_body text) returns void
language plpgsql security definer set search_path = public, private as $$
declare e record; targets uuid[];
begin
  select primary_vol, backup_vol into e from elders where id = p_elder;
  if p_level = 1 and e.primary_vol is not null then targets := array[e.primary_vol];
  elsif p_level = 2 and e.backup_vol is not null then targets := array[e.backup_vol];
  else select array_agg(id) into targets from profiles where active and role in ('chief','social','admin');
  end if;
  insert into private.notifications(user_id, title, body, url, tag)
  select t, p_title, p_body, 'care.html?e=' || p_elder, 'elder-' || p_elder
  from unnest(coalesce(targets, '{}'::uuid[])) as t where t is not null;
end $$;

-- 呼叫 Edge Function 把排隊中的通知推出去
create or replace function private.flush_push() returns void
language plpgsql security definer set search_path = public, private as $$
declare u text; s text;
begin
  select value into u from private.config where key = 'push_url';
  select value into s from private.config where key = 'cron_secret';
  if u is null or s is null then return; end if;
  if not exists(select 1 from private.notifications where sent_at is null) then return; end if;
  perform net.http_post(
    url     := u,
    body    := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', s)
  );
end $$;

-- ════════════════ 自動判斷與升級（每分鐘執行）════════════════
create or replace function private.run_escalation() returns void
language plpgsql security definer set search_path = public, private as $$
declare
  st settings; e record; c record; cid uuid;
  now_tw timestamp := now() at time zone 'Asia/Taipei';
  today  date := (now() at time zone 'Asia/Taipei')::date;
begin
  select * into st from settings where id = 1;

  -- ① 過了回報時間還沒平安 → 開案、推播主責志工
  for e in
    select el.* from elders el
    where el.active
      and now_tw::time >= el.deadline
      and not ((el.created_at at time zone 'Asia/Taipei')::date = today
               and (el.created_at at time zone 'Asia/Taipei')::time > el.deadline)
      and not exists(select 1 from checkins k where k.elder_id = el.id and k.day = today and k.kind in ('ok','call'))
      and not exists(select 1 from cases cs where cs.elder_id = el.id and cs.day = today)
  loop
    cid := null;
    insert into cases(elder_id, day, reason) values (e.id, today, 'overdue')
      on conflict (elder_id, day) do nothing returning id into cid;
    if cid is not null then
      insert into case_events(case_id, action, stage)
        values (cid, '系統：' || to_char(e.deadline, 'HH24:MI') || ' 前未回報，已開案並通知主責志工', 1);
      perform private.notify_level(e.id, 1, '🔴 ' || e.name || ' 逾時未回報',
        to_char(e.deadline, 'HH24:MI') || ' 前沒有回報平安，請打電話確認');
    end if;
  end loop;

  -- ② 主責志工 N 分鐘內沒有任何處理 → 轉交備援
  for c in
    select cs.id, cs.stage, cs.elder_id, el.name
    from cases cs join elders el on el.id = cs.elder_id
    where cs.closed_at is null and cs.level = 1 and cs.last_human_at is null
      and cs.day >= today - 1
      and now() - cs.opened_at >= make_interval(mins => st.backup_after_min)
  loop
    update cases set level = 2, level_changed_at = now() where id = c.id;
    insert into case_events(case_id, action, stage)
      values (c.id, '系統：主責志工 ' || st.backup_after_min || ' 分鐘內未處理，已轉交備援志工', c.stage);
    perform private.notify_level(c.elder_id, 2, '⏫ 轉交給您：' || c.name, '主責志工尚未處理，請協助確認平安');
  end loop;

  -- ③ 開案超過 M 分鐘仍未確認平安 → 通報里長／社工
  for c in
    select cs.id, cs.stage, cs.elder_id, el.name
    from cases cs join elders el on el.id = cs.elder_id
    where cs.closed_at is null and cs.level < 3
      and cs.day >= today - 1
      and now() - cs.opened_at >= make_interval(mins => st.chief_after_min)
  loop
    update cases set level = 3, level_changed_at = now() where id = c.id;
    insert into case_events(case_id, action, stage)
      values (c.id, '系統：開案 ' || st.chief_after_min || ' 分鐘仍未確認平安，已通報里長／社工', c.stage);
    perform private.notify_level(c.elder_id, 3, '🚨 ' || c.name || ' 尚未確認平安',
      '已超過 ' || st.chief_after_min || ' 分鐘，請里長／社工協助');
  end loop;

  perform private.flush_push();
end $$;

-- ════════════════ 長輩端（不用登入，只憑專屬代碼）════════════════
create or replace function public.elder_info(p_token text) returns json
language plpgsql stable security definer set search_path = public, private as $$
declare e elders; v record; today date := (now() at time zone 'Asia/Taipei')::date;
begin
  select * into e from elders where token = upper(trim(p_token)) and active;
  if not found then return json_build_object('ok', false); end if;
  select name, phone into v from profiles where id = e.primary_vol;
  return json_build_object(
    'ok', true, 'name', e.name, 'mode', e.mode,
    'deadline',  to_char(e.deadline, 'HH24:MI'),
    'vol_name',  coalesce(nullif(v.name, ''), '志工'),
    'vol_phone', coalesce(v.phone, ''),
    'village',   (select village from settings where id = 1),
    'ok_at',     (select to_char(min(at) at time zone 'Asia/Taipei', 'HH24:MI') from checkins
                  where elder_id = e.id and day = today and kind = 'ok' and source = 'elder'),
    'help_at',   (select to_char(max(at) at time zone 'Asia/Taipei', 'HH24:MI') from checkins
                  where elder_id = e.id and day = today and kind = 'help'),
    'streak',    private.streak(e.id));
end $$;

create or replace function public.elder_report(p_token text, p_kind text, p_client_at timestamptz default null) returns json
language plpgsql security definer set search_path = public, private as $$
declare
  e elders; c cases; t timestamptz := now(); existing timestamptz;
  today date := (now() at time zone 'Asia/Taipei')::date;
begin
  select * into e from elders where token = upper(trim(p_token)) and active;
  if not found then return json_build_object('ok', false, 'error', 'invalid'); end if;

  -- 離線時先記下的時間：同一天、六小時內才採用
  if p_client_at is not null and p_client_at <= now() and p_client_at > now() - interval '6 hours'
     and (p_client_at at time zone 'Asia/Taipei')::date = today then
    t := p_client_at;
  end if;

  if p_kind = 'ok' then
    select min(at) into existing from checkins
      where elder_id = e.id and day = today and kind = 'ok' and source = 'elder';
    if existing is null then
      insert into checkins(elder_id, day, kind, at, source) values (e.id, today, 'ok', t, 'elder');
      existing := t;
      select * into c from cases where elder_id = e.id and day = today and closed_at is null;
      if c.id is not null then
        if c.reason = 'overdue' and not c.need_help then
          update cases set stage = 6, closed_at = now() where id = c.id;
          insert into case_events(case_id, action, stage)
            values (c.id, '長輩自行回報平安（' || to_char(t at time zone 'Asia/Taipei', 'HH24:MI') || '），系統結案', 6);
          perform private.notify_level(e.id, greatest(c.level, 1), '🟢 ' || e.name || ' 已回報平安', '系統已自動結案，謝謝您');
          perform private.flush_push();
        else
          insert into case_events(case_id, action, stage) values (c.id, '長輩按了「我今天平安」', c.stage);
        end if;
      end if;
    end if;
    return json_build_object('ok', true, 'kind', 'ok',
      'at', to_char(existing at time zone 'Asia/Taipei', 'HH24:MI'), 'streak', private.streak(e.id));

  elsif p_kind = 'help' then
    select max(at) into existing from checkins
      where elder_id = e.id and kind = 'help' and at > now() - interval '10 minutes';
    if existing is not null then   -- 十分鐘內重複按，不重複通知
      return json_build_object('ok', true, 'kind', 'help', 'dup', true,
        'at', to_char(existing at time zone 'Asia/Taipei', 'HH24:MI'));
    end if;
    insert into checkins(elder_id, day, kind, at, source) values (e.id, today, 'help', now(), 'elder');
    select * into c from cases where elder_id = e.id and day = today;
    if c.id is null then
      insert into cases(elder_id, day, reason, need_help) values (e.id, today, 'help', true) returning * into c;
      insert into case_events(case_id, action, stage) values (c.id, '長輩按了「我需要幫忙」', 1);
    elsif c.closed_at is not null then
      update cases set closed_at = null, closed_by = null, stage = 1, level = 1, reason = 'help', need_help = true,
        opened_at = now(), level_changed_at = now(), last_human_at = null where id = c.id;
      insert into case_events(case_id, action, stage) values (c.id, '長輩再次按了「我需要幫忙」，重新開案', 1);
    else
      update cases set need_help = true where id = c.id;
      insert into case_events(case_id, action, stage) values (c.id, '長輩按了「我需要幫忙」', c.stage);
    end if;
    perform private.notify_level(e.id, 1, '🟠 ' || e.name || ' 按了「我需要幫忙」', '請盡快打電話關心');
    perform private.flush_push();
    return json_build_object('ok', true, 'kind', 'help', 'at', to_char(now() at time zone 'Asia/Taipei', 'HH24:MI'));
  end if;

  return json_build_object('ok', false, 'error', 'kind');
end $$;

-- ════════════════ 志工端 ════════════════
-- 今日工作台：所有長輩＋今日狀態＋近 7 天
create or replace function public.board_today() returns json
language plpgsql stable security definer set search_path = public, private as $$
declare today date := (now() at time zone 'Asia/Taipei')::date; r json;
begin
  if not is_staff() then raise exception '帳號尚未開通'; end if;
  select coalesce(json_agg(x order by x.deadline, x.name), '[]'::json) into r from (
    select e.id, e.name, e.mode, to_char(e.deadline, 'HH24:MI') as deadline, e.phone,
      e.family_name, e.family_phone, e.note, e.token, e.consent,
      e.primary_vol, e.backup_vol,
      pv.name as primary_name, pv.phone as primary_phone,
      bv.name as backup_name,  bv.phone as backup_phone,
      private.day_status(e.id, today) as today_status,
      (select min(k.at) from checkins k where k.elder_id = e.id and k.day = today and k.kind in ('ok','call')) as today_safe_at,
      (select max(k.at) from checkins k where k.elder_id = e.id and k.day = today and k.kind = 'help') as help_at,
      (select row_to_json(cc) from (
         select cs.id, cs.reason, cs.stage, cs.level, cs.need_help, cs.opened_at, cs.closed_at,
                cs.last_human_at, cs.level_changed_at,
                (select json_build_object('at', ce.at, 'action', ce.action, 'note', ce.note, 'actor', p.name)
                   from case_events ce left join profiles p on p.id = ce.actor
                   where ce.case_id = cs.id order by ce.at desc, ce.id desc limit 1) as last_event
         from cases cs where cs.elder_id = e.id and cs.day = today) cc) as today_case,
      (select max(k.at) from checkins k where k.elder_id = e.id and k.kind in ('ok','call')) as last_ok_at,
      private.streak(e.id) as streak,
      (select json_agg(private.day_status(e.id, g::date) order by g)
         from generate_series(today - 6, today, interval '1 day') g) as dots7,
      (select count(*) from generate_series(today - 6, today, interval '1 day') g
         where private.day_status(e.id, g::date) = 'late') as late7,
      (select count(*) from generate_series(today - 7, today - 1, interval '1 day') g
         where private.day_status(e.id, g::date) in ('miss','checked')) as miss7
    from elders e
    left join profiles pv on pv.id = e.primary_vol
    left join profiles bv on bv.id = e.backup_vol
    where e.active
  ) x;
  return r;
end $$;

-- 長輩個人統計與 30 天趨勢
create or replace function public.elder_stats(p_elder uuid) returns json
language plpgsql stable security definer set search_path = public, private as $$
declare
  today date := (now() at time zone 'Asia/Taipei')::date;
  ms    date := date_trunc('month', (now() at time zone 'Asia/Taipei'))::date;
  r json;
begin
  if not is_staff() then raise exception '帳號尚未開通'; end if;
  with days as (
    select g::date as day, private.day_status(p_elder, g::date) as st
    from generate_series(today - 89, today, interval '1 day') g
  ), okt as (
    select day, extract(epoch from (ok_at at time zone 'Asia/Taipei')::time) / 60 as m
    from private.v_ok where elder_id = p_elder and day > today - 30
  )
  select json_build_object(
    'last_ok_at',    (select max(at) from checkins where elder_id = p_elder and kind in ('ok','call')),
    'last_self_at',  (select max(ok_at) from private.v_ok where elder_id = p_elder),
    'streak',        private.streak(p_elder),
    'month_good',    (select count(*) from private.v_ok where elder_id = p_elder and day >= ms and day <= today),
    'month_total',   (select count(*) from days where day >= ms and st not in ('none','wait')),
    'last_abnormal', (select max(day) from days where st in ('miss','help','checked')),
    'days30',        (select json_agg(json_build_object('d', day, 's', st) order by day) from days where day > today - 30),
    'avg7',          (select avg(m) from okt where day > today - 7),
    'n7',            (select count(*) from okt where day > today - 7),
    'avg_prev',      (select avg(m) from okt where day <= today - 7),
    'n_prev',        (select count(*) from okt where day <= today - 7)
  ) into r;
  return r;
end $$;

-- 志工的處理動作（全部經過這裡，才能留下完整紀錄）
create or replace function public.case_action(p_elder uuid, p_action text, p_note text default '') returns json
language plpgsql security definer set search_path = public, private as $$
declare
  today date := (now() at time zone 'Asia/Taipei')::date;
  me uuid := auth.uid(); e elders; c cases; newstage int; msg text;
begin
  if not is_staff() then raise exception '帳號尚未開通'; end if;
  select * into e from elders where id = p_elder;
  if not found then raise exception '找不到這位長輩'; end if;
  p_note := left(coalesce(p_note, ''), 200);

  if p_action = 'undo_ok' then
    delete from checkins where elder_id = p_elder and day = today and source = 'volunteer' and kind in ('ok','call');
    return json_build_object('ok', true);
  end if;

  select * into c from cases where elder_id = p_elder and day = today;

  if c.id is null then
    if p_action = 'confirm_safe' then     -- 沒有個案：單純電話問安平安
      insert into checkins(elder_id, day, kind, source, by_user, note) values (p_elder, today, 'call', 'volunteer', me, p_note);
      return json_build_object('ok', true);
    end if;
    insert into cases(elder_id, day, reason, need_help)
      values (p_elder, today, case when p_action = 'need_help' then 'help' else 'overdue' end, p_action = 'need_help')
      returning * into c;
    insert into case_events(case_id, actor, action, stage) values (c.id, me, '志工開案', 1);
  elsif c.closed_at is not null and p_action not in ('note') then
    update cases set closed_at = null, closed_by = null, stage = 1, level = 1,
      opened_at = now(), level_changed_at = now() where id = c.id returning * into c;
    insert into case_events(case_id, actor, action, stage) values (c.id, me, '重新開案', 1);
  end if;

  newstage := c.stage;
  if p_action = 'call_noanswer' then
    newstage := case when c.stage < 2 then 2 when c.stage = 2 then 3 else c.stage end;
    msg := case when c.stage < 2 then '第一次聯絡未接' when c.stage = 2 then '第二次聯絡未接' else '再次聯絡未接' end;
  elsif p_action = 'notify_family' then
    newstage := greatest(c.stage, 4);
    msg := '已通知家屬' || coalesce('（' || nullif(e.family_name, '') || '）', '');
  elsif p_action = 'notify_chief' then
    newstage := greatest(c.stage, 5);
    msg := '已通知里長／社工';
  elsif p_action = 'need_help' then
    update cases set need_help = true where id = c.id;
    msg := '需要協助';
  elsif p_action = 'confirm_safe' then
    newstage := 6;
    msg := '已確認安全，結案';
    insert into checkins(elder_id, day, kind, source, by_user, note) values (p_elder, today, 'call', 'volunteer', me, p_note);
  elsif p_action = 'note' then
    msg := '補充紀錄';
  else
    raise exception '未知的動作：%', p_action;
  end if;

  update cases set stage = newstage, last_human_at = now(),
    closed_at = case when newstage = 6 then now() else closed_at end,
    closed_by = case when newstage = 6 then me else closed_by end
  where id = c.id;
  insert into case_events(case_id, actor, action, stage, note) values (c.id, me, msg, newstage, p_note);
  return json_build_object('ok', true, 'stage', newstage);
end $$;

-- 每月報表
create or replace function public.month_report(p_month text) returns json
language plpgsql stable security definer set search_path = public, private as $$
declare
  today date := (now() at time zone 'Asia/Taipei')::date;
  d0 date := (p_month || '-01')::date;
  d1 date;
  r json;
begin
  if not is_staff() then raise exception '帳號尚未開通'; end if;
  d1 := least((d0 + interval '1 month' - interval '1 day')::date, today);
  select coalesce(json_agg(json_build_object(
      'day', g::date, 'name', e.name, 'mode', e.mode,
      'status', private.day_status(e.id, g::date),
      'ok_at', (select to_char(min(k.at) at time zone 'Asia/Taipei', 'HH24:MI') from checkins k
                where k.elder_id = e.id and k.day = g::date and k.kind in ('ok','call')),
      'stage', (select cs.stage from cases cs where cs.elder_id = e.id and cs.day = g::date),
      'events', (select string_agg(to_char(ce.at at time zone 'Asia/Taipei', 'HH24:MI') || ' ' || ce.action
                   || coalesce('：' || nullif(ce.note, ''), ''), '；' order by ce.at)
                 from case_events ce join cases cs on cs.id = ce.case_id
                 where cs.elder_id = e.id and cs.day = g::date)
    ) order by g, e.name), '[]'::json) into r
  from elders e cross join generate_series(d0, d1, interval '1 day') g;
  return r;
end $$;

-- 匯入舊版平安鈴備份檔（app: peace-board）
create or replace function public.import_legacy(p jsonb) returns json
language plpgsql security definer set search_path = public, private as $$
declare
  el jsonb; newid uuid; d text; rec record; n int := 0; m int := 0;
  idmap jsonb := '{}'::jsonb; first_day date;
begin
  if not is_manager() then raise exception '只有里長、社工或管理者可以匯入'; end if;
  if coalesce(p->>'app', '') <> 'peace-board' then raise exception '這不是平安鈴的備份檔'; end if;
  select min(k)::date into first_day from jsonb_object_keys(coalesce(p->'log', '{}'::jsonb)) k;
  for el in select * from jsonb_array_elements(coalesce(p->'elders', '[]'::jsonb)) loop
    begin
      insert into elders(name, mode, deadline, phone, family_name, family_phone, note, consent, primary_vol, created_at)
      values (left(coalesce(nullif(el->>'n', ''), '未命名'), 16),
              case when el->>'mode' = 'call' then 'call' else 'self' end,
              coalesce(nullif(el->>'t', '')::time, '10:00'),
              coalesce(el->>'phone', ''), coalesce(el->>'ecn', ''), coalesce(el->>'ecp', ''),
              left(coalesce(el->>'note', ''), 60), true, auth.uid(),
              coalesce(first_day::timestamp at time zone 'Asia/Taipei', now()))
      returning id into newid;
      idmap := idmap || jsonb_build_object(el->>'id', newid::text);
      n := n + 1;
    exception when others then null;
    end;
  end loop;
  for d in select jsonb_object_keys(coalesce(p->'log', '{}'::jsonb)) loop
    for rec in select key, value from jsonb_each(p->'log'->d) loop
      begin
        if idmap ? rec.key and rec.value->>'st' in ('ok','call','help') then
          insert into checkins(elder_id, day, kind, at, source, by_user, note) values (
            (idmap->>rec.key)::uuid, d::date, rec.value->>'st',
            ((d || ' ' || coalesce(nullif(rec.value->>'t', ''), '12:00'))::timestamp at time zone 'Asia/Taipei'),
            case when rec.value->>'st' = 'ok' then 'elder' else 'volunteer' end,
            case when rec.value->>'st' = 'ok' then null else auth.uid() end,
            left(coalesce(rec.value->>'note', ''), 200));
          m := m + 1;
        end if;
      exception when others then null;
      end;
    end loop;
  end loop;
  return json_build_object('elders', n, 'records', m);
end $$;

create or replace function public.set_my_profile(p_name text, p_phone text) returns void
language sql security definer set search_path = public as $$
  update profiles set name = left(trim(p_name), 12), phone = left(trim(p_phone), 20) where id = auth.uid();
$$;

create or replace function public.save_subscription(p_endpoint text, p_p256dh text, p_auth text, p_ua text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  delete from push_subscriptions where endpoint = p_endpoint;
  insert into push_subscriptions(endpoint, user_id, p256dh, auth, ua)
    values (p_endpoint, auth.uid(), p_p256dh, p_auth, left(coalesce(p_ua, ''), 200));
end $$;

create or replace function public.test_push() returns json
language plpgsql security definer set search_path = public, private as $$
begin
  if not is_staff() then raise exception '帳號尚未開通'; end if;
  insert into private.notifications(user_id, title, body, url, tag)
    values (auth.uid(), '🔔 平安鈴測試通知', '看到這則通知，代表推播設定成功了', 'care.html', 'test');
  perform private.flush_push();
  return json_build_object('ok', true,
    'subscriptions', (select count(*) from push_subscriptions where user_id = auth.uid()),
    'configured', exists(select 1 from private.config where key = 'push_url'));
end $$;

-- 給 Edge Function（service_role）取出待送通知
create or replace function public.claim_notifications() returns json
language plpgsql security definer set search_path = public, private as $$
declare r json;
begin
  update private.notifications set sent_at = now()
    where sent_at is null and created_at <= now() - interval '2 hours';   -- 太舊的不送了
  with n as (
    update private.notifications set sent_at = now() where sent_at is null returning *
  )
  select coalesce(json_agg(json_build_object(
      'title', n.title, 'body', n.body, 'url', n.url, 'tag', n.tag,
      'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)), '[]'::json)
    into r
  from n join push_subscriptions s on s.user_id = n.user_id;
  return r;
end $$;

-- ════════════════ 權限（RLS）════════════════
alter table public.settings           enable row level security;
alter table public.profiles           enable row level security;
alter table public.elders             enable row level security;
alter table public.checkins           enable row level security;
alter table public.cases              enable row level security;
alter table public.case_events        enable row level security;
alter table public.push_subscriptions enable row level security;

drop policy if exists "staff read settings" on public.settings;
create policy "staff read settings" on public.settings for select to authenticated using (public.is_staff());
drop policy if exists "admin update settings" on public.settings;
create policy "admin update settings" on public.settings for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "read profiles" on public.profiles;
create policy "read profiles" on public.profiles for select to authenticated using (public.is_staff() or id = auth.uid());
drop policy if exists "admin update profiles" on public.profiles;
create policy "admin update profiles" on public.profiles for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "staff read elders" on public.elders;
create policy "staff read elders" on public.elders for select to authenticated using (public.is_staff());
drop policy if exists "manager insert elders" on public.elders;
create policy "manager insert elders" on public.elders for insert to authenticated with check (public.is_manager());
drop policy if exists "manager update elders" on public.elders;
create policy "manager update elders" on public.elders for update to authenticated
  using (public.is_manager()) with check (public.is_manager());
drop policy if exists "admin delete elders" on public.elders;
create policy "admin delete elders" on public.elders for delete to authenticated using (public.is_admin());

drop policy if exists "staff read checkins" on public.checkins;
create policy "staff read checkins" on public.checkins for select to authenticated using (public.is_staff());
drop policy if exists "staff read cases" on public.cases;
create policy "staff read cases" on public.cases for select to authenticated using (public.is_staff());
drop policy if exists "staff read events" on public.case_events;
create policy "staff read events" on public.case_events for select to authenticated using (public.is_staff());

drop policy if exists "own subscriptions" on public.push_subscriptions;
create policy "own subscriptions" on public.push_subscriptions for select to authenticated using (user_id = auth.uid());
drop policy if exists "delete own subscriptions" on public.push_subscriptions;
create policy "delete own subscriptions" on public.push_subscriptions for delete to authenticated using (user_id = auth.uid());

-- 函式權限：未登入（anon）只能用長輩端兩個函式
revoke execute on all functions in schema public  from public, anon;
revoke execute on all functions in schema private from public, anon, authenticated;
grant  execute on function public.elder_info(text)                          to anon, authenticated;
grant  execute on function public.elder_report(text, text, timestamptz)     to anon, authenticated;
grant  execute on function public.is_staff(), public.is_manager(), public.is_admin(),
       public.new_token(), public.board_today(), public.elder_stats(uuid),
       public.case_action(uuid, text, text), public.month_report(text), public.import_legacy(jsonb),
       public.set_my_profile(text, text), public.save_subscription(text, text, text, text),
       public.test_push()                                                   to authenticated;
revoke execute on function public.claim_notifications() from authenticated;
grant  execute on function public.claim_notifications() to service_role;

-- ════════════════ 即時同步（工作台自動更新）════════════════
do $$
declare t text;
begin
  foreach t in array array['checkins','cases','case_events'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ════════════════ 排程：每分鐘檢查一次 ════════════════
select cron.unschedule(jobid) from cron.job where jobname = 'peacebell-escalation';
select cron.schedule('peacebell-escalation', '* * * * *', 'select private.run_escalation()');
