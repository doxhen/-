-- ============================================================================
--  도훈갤 · Supabase 스키마 (PostgreSQL)
--  Supabase 대시보드 → SQL Editor 에 이 파일 전체를 붙여넣고 실행하세요.
--  앱(index.html)의 SupabaseStore 어댑터가 이 구조를 그대로 사용합니다.
--
--  테이블  profiles / galleries / posts / comments / votes
--  뷰      post_list (추천·비추·댓글 수, 개념글 여부)
--  함수    is_admin(), increment_post_views(), handle_new_user() 트리거
--  정책    RLS: 읽기는 공개, 쓰기는 본인, 삭제는 본인 또는 관리자
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 0. 확장
-- ---------------------------------------------------------------------------
create extension if not exists "pgcrypto";   -- gen_random_uuid()
create extension if not exists "citext";     -- profiles.username / nickname 대소문자 무시


-- ---------------------------------------------------------------------------
-- 1. profiles — auth.users 1:1 확장 (아이디/닉네임/관리자 여부)
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  username    citext unique not null
              check (username ~ '^[A-Za-z0-9_]{4,16}$'),
  nickname    citext unique not null
              check (char_length(nickname) between 2 and 12),
  is_admin    boolean not null default false,
  created_at  timestamptz not null default now()
);

comment on table  public.profiles is '회원 프로필. auth.users 가입 시 트리거로 자동 생성됩니다.';
comment on column public.profiles.username is '로그인 아이디(이메일과 별개). 영문·숫자·밑줄 4~16자.';
comment on column public.profiles.is_admin is '관리자 여부. 글·댓글 삭제 권한을 가집니다.';


-- ---------------------------------------------------------------------------
-- 2. galleries — 갤러리(게시판) 목록
-- ---------------------------------------------------------------------------
create table if not exists public.galleries (
  id          text primary key,                -- 'free', 'game', 'soccer', 'info'
  name        text not null,
  description text,
  icon        text,
  sort_order  int  not null default 0,
  created_at  timestamptz not null default now()
);


-- ---------------------------------------------------------------------------
-- 3. posts — 게시글
-- ---------------------------------------------------------------------------
create table if not exists public.posts (
  id          bigserial primary key,
  gallery_id  text not null references public.galleries (id) on delete cascade,
  author_id   uuid not null references public.profiles (id) on delete cascade,
  head        text not null default '일반'
              check (head in ('일반', '질문', '정보', '뉴스', '후기')),
  title       text not null check (char_length(title) between 1 and 80),
  body        text not null check (char_length(body) between 1 and 10000),
  views       int  not null default 0 check (views >= 0),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists posts_gallery_created_idx on public.posts (gallery_id, created_at desc);
create index if not exists posts_author_idx          on public.posts (author_id);


-- ---------------------------------------------------------------------------
-- 4. comments — 댓글 & 대댓글 (parent_id 자기참조, 1단계 대댓글 사용)
-- ---------------------------------------------------------------------------
create table if not exists public.comments (
  id          bigserial primary key,
  post_id     bigint not null references public.posts (id) on delete cascade,
  author_id   uuid   not null references public.profiles (id) on delete cascade,
  parent_id   bigint references public.comments (id) on delete cascade,
  body        text   not null check (char_length(body) between 1 and 2000),
  created_at  timestamptz not null default now()
);

create index if not exists comments_post_idx   on public.comments (post_id, created_at);
create index if not exists comments_parent_idx on public.comments (parent_id);


-- ---------------------------------------------------------------------------
-- 5. votes — 개추(+1) / 비추(-1). 한 사람이 한 글에 한 표만.
-- ---------------------------------------------------------------------------
create table if not exists public.votes (
  post_id     bigint not null references public.posts (id) on delete cascade,
  user_id     uuid   not null references public.profiles (id) on delete cascade,
  value       smallint not null check (value in (-1, 1)),
  created_at  timestamptz not null default now(),
  primary key (post_id, user_id)
);

create index if not exists votes_post_idx on public.votes (post_id);


-- ---------------------------------------------------------------------------
-- 6. 헬퍼 함수
-- ---------------------------------------------------------------------------

-- 현재 사용자가 관리자인가?
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select p.is_admin from public.profiles p where p.id = auth.uid()),
    false
  );
$$;

-- updated_at 자동 갱신
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists posts_touch_updated_at on public.posts;
create trigger posts_touch_updated_at
  before update on public.posts
  for each row execute function public.touch_updated_at();

-- 조회수 +1 (누구나 호출 가능, security definer 로 RLS 우회)
create or replace function public.increment_post_views(p_id bigint)
returns void
language sql
security definer
set search_path = public
as $$
  update public.posts set views = views + 1 where id = p_id;
$$;

grant execute on function public.increment_post_views(bigint) to anon, authenticated;

-- 회원가입 시 profiles 자동 생성
--   raw_user_meta_data: { username, nickname }
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_username text;
  v_nickname text;
begin
  v_username := coalesce(
    nullif(new.raw_user_meta_data ->> 'username', ''),
    'user_' || substr(replace(new.id::text, '-', ''), 1, 10)
  );
  v_nickname := coalesce(
    nullif(new.raw_user_meta_data ->> 'nickname', ''),
    '갤러' || substr(replace(new.id::text, '-', ''), 1, 5)
  );

  begin
    insert into public.profiles (id, username, nickname, is_admin)
    values (
      new.id,
      v_username,
      v_nickname,
      -- 첫 가입자에게 관리자 권한 (원치 않으면 이 부분을 false 로 바꾸세요)
      not exists (select 1 from public.profiles where is_admin)
    );
  exception when unique_violation then
    -- 아이디/닉네임이 이미 쓰이면 자동으로 뒤에 붙여 가입은 계속되게 한다.
    insert into public.profiles (id, username, nickname, is_admin)
    values (
      new.id,
      left(v_username, 8) || '_' || substr(replace(new.id::text, '-', ''), 1, 6),
      left(v_nickname, 8) || '_' || substr(replace(new.id::text, '-', ''), 1, 3),
      false
    );
  end;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 관리자 플래그는 본인이 바꿀 수 없게 막기
create or replace function public.protect_admin_flag()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.is_admin <> old.is_admin and auth.uid() is not null and not public.is_admin() then
    raise exception '관리자 권한은 직접 변경할 수 없습니다.';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_protect_admin_flag on public.profiles;
create trigger profiles_protect_admin_flag
  before update on public.profiles
  for each row execute function public.protect_admin_flag();


-- ---------------------------------------------------------------------------
-- 7. post_list — 목록 화면용 뷰 (추천/비추/댓글 수 + 개념글 여부)
--    개념글 기준: 추천 10개 이상 (앱의 CONFIG.conceptThreshold 와 동일)
-- ---------------------------------------------------------------------------
create or replace view public.post_list
with (security_invoker = true)
as
select
  q.id,
  q.gallery_id,
  q.author_id,
  q.head,
  q.title,
  q.body,
  q.views,
  q.created_at,
  q.nickname,
  q.is_admin,
  q.recommend_count,
  q.dislike_count,
  q.comment_count,
  (q.recommend_count >= 10) as is_concept
from (
  select
    p.id,
    p.gallery_id,
    p.author_id,
    p.head,
    p.title,
    p.body,
    p.views,
    p.created_at,
    pr.nickname,
    pr.is_admin,
    (select count(*) from public.votes v where v.post_id = p.id and v.value =  1) as recommend_count,
    (select count(*) from public.votes v where v.post_id = p.id and v.value = -1) as dislike_count,
    (select count(*) from public.comments c where c.post_id = p.id)                    as comment_count
  from public.posts p
  join public.profiles pr on pr.id = p.author_id
) q;

comment on view public.post_list is '게시글 목록/상세 공용 뷰. is_concept = 추천 10개 이상.';


-- ---------------------------------------------------------------------------
-- 8. RLS (Row Level Security)
--    · 읽기: 누구나 (비로그인 포함)
--    · 쓰기: 로그인 + 본인 글
--    · 수정/삭제: 작성자 본인 또는 관리자
--    · 추천: 본인 표만 (1인 1표)
-- ---------------------------------------------------------------------------
alter table public.profiles  enable row level security;
alter table public.galleries enable row level security;
alter table public.posts     enable row level security;
alter table public.comments  enable row level security;
alter table public.votes     enable row level security;

-- profiles ---------------------------------------------------------------
drop policy if exists "profiles: 공개 읽기"      on public.profiles;
drop policy if exists "profiles: 본인 행 생성"    on public.profiles;
drop policy if exists "profiles: 본인 행 수정"    on public.profiles;

create policy "profiles: 공개 읽기"
  on public.profiles for select
  using (true);

create policy "profiles: 본인 행 생성"
  on public.profiles for insert
  to authenticated
  with check (id = auth.uid());

create policy "profiles: 본인 행 수정"
  on public.profiles for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- galleries --------------------------------------------------------------
drop policy if exists "galleries: 공개 읽기" on public.galleries;

create policy "galleries: 공개 읽기"
  on public.galleries for select
  using (true);

-- posts ------------------------------------------------------------------
drop policy if exists "posts: 공개 읽기"        on public.posts;
drop policy if exists "posts: 로그인 후 작성"     on public.posts;
drop policy if exists "posts: 본인 또는 관리자 수정" on public.posts;
drop policy if exists "posts: 본인 또는 관리자 삭제" on public.posts;

create policy "posts: 공개 읽기"
  on public.posts for select
  using (true);

create policy "posts: 로그인 후 작성"
  on public.posts for insert
  to authenticated
  with check (author_id = auth.uid());

create policy "posts: 본인 또는 관리자 수정"
  on public.posts for update
  to authenticated
  using (author_id = auth.uid() or public.is_admin())
  with check (author_id = auth.uid() or public.is_admin());

create policy "posts: 본인 또는 관리자 삭제"
  on public.posts for delete
  to authenticated
  using (author_id = auth.uid() or public.is_admin());

-- comments ---------------------------------------------------------------
drop policy if exists "comments: 공개 읽기"          on public.comments;
drop policy if exists "comments: 로그인 후 작성"       on public.comments;
drop policy if exists "comments: 본인 또는 관리자 수정"  on public.comments;
drop policy if exists "comments: 본인 또는 관리자 삭제"  on public.comments;

create policy "comments: 공개 읽기"
  on public.comments for select
  using (true);

create policy "comments: 로그인 후 작성"
  on public.comments for insert
  to authenticated
  with check (author_id = auth.uid());

create policy "comments: 본인 또는 관리자 수정"
  on public.comments for update
  to authenticated
  using (author_id = auth.uid() or public.is_admin())
  with check (author_id = auth.uid() or public.is_admin());

create policy "comments: 본인 또는 관리자 삭제"
  on public.comments for delete
  to authenticated
  using (author_id = auth.uid() or public.is_admin());

-- votes ------------------------------------------------------------------
drop policy if exists "votes: 공개 읽기"      on public.votes;
drop policy if exists "votes: 본인 표 추가"    on public.votes;
drop policy if exists "votes: 본인 표 변경"    on public.votes;
drop policy if exists "votes: 본인 표 삭제"    on public.votes;

create policy "votes: 공개 읽기"
  on public.votes for select
  using (true);

create policy "votes: 본인 표 추가"
  on public.votes for insert
  to authenticated
  with check (user_id = auth.uid());

create policy "votes: 본인 표 변경"
  on public.votes for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "votes: 본인 표 삭제"
  on public.votes for delete
  to authenticated
  using (user_id = auth.uid());


-- ---------------------------------------------------------------------------
-- 9. 기본 갤러리
-- ---------------------------------------------------------------------------
insert into public.galleries (id, name, description, icon, sort_order) values
  ('free',   '자유 갤러리',      '아무 말이나 편하게 올리는 곳',      '💬', 1),
  ('game',   '게임 갤러리',      '게임 이야기, 패치, 세일 정보',      '🎮', 2),
  ('soccer', '축구 갤러리',      'K리그부터 해외축구까지',            '⚽', 3),
  ('info',   '질문·정보 갤러리', '공부·입시 질문과 정보 공유',        '📚', 4)
on conflict (id) do update
  set name = excluded.name,
      description = excluded.description,
      icon = excluded.icon,
      sort_order = excluded.sort_order;


-- ---------------------------------------------------------------------------
-- 10. 첫 관리자 지정 (선택)
--     가입은 Supabase Auth 로 먼저 한 뒤, 아래 주석을 아이디만 바꿔 실행하세요.
--     (handle_new_user 트리거가 첫 가입자를 자동 관리자로 만들므로 보통 불필요)
-- ---------------------------------------------------------------------------
-- update public.profiles set is_admin = true where username = 'my_admin_id';


-- ---------------------------------------------------------------------------
-- 11. 앱 연동 체크리스트
-- ---------------------------------------------------------------------------
--  1) Authentication → Providers → Email 활성화
--     · 데모/테스트라면 "Confirm email" 을 꺼 두면 가입 즉시 로그인됩니다.
--  2) Authentication → URL Configuration 에 배포 도메인 추가
--  3) index.html 에서
--       <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
--     를 </body> 앞에 추가하고
--       CONFIG.backend = 'supabase'
--       CONFIG.supabaseUrl = 'https://<project>.supabase.co'
--       CONFIG.supabaseAnonKey = '<anon public key>'
--     를 채우면 localStorage 대신 이 스키마를 사용합니다.
--  4) 댓글 작성 시 profiles 조인은 RLS 공개 읽기 정책으로 동작합니다.
--  5) 개념글 기준을 바꾸려면 post_list 뷰의 (recommend_count >= 10) 과
--     index.html 의 CONFIG.conceptThreshold 를 함께 수정하세요.
-- ============================================================================
