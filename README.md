# 도훈갤 — 디시인사이드 스타일 회원제 커뮤니티

## 현재 배포 상태

- 사이트: https://doxhen.github.io/-/ (GitHub Pages, `main` 브랜치 루트)
- 저장소: https://github.com/doxhen/-
- DB/인증: Supabase 프로젝트 `dohoon-gallery` (리전 ap-northeast-2) — `CONFIG.backend = 'supabase'` 로 연동됨
- **회원가입은 이메일 인증 방식**입니다. 가입 시 메일로 온 인증 링크를 눌러야 가입이 완료되고, 링크를 누르면 사이트로 돌아와 바로 로그인됩니다.
  - Supabase 무료 기본 메일러는 **시간당 2통**까지만 발송됩니다(대시보드 Auth → Rate Limits). 인증 메일이 안 오면 스팸함을 확인하고, 한도를 넘었다면 1시간 뒤 다시 시도해야 합니다.
  - 인증 메일의 기본 문구는 영어입니다. 바꾸려면 Supabase 대시보드 Auth → Emails → Confirm signup 템플릿을 수정하거나 커스텀 SMTP를 연결하세요.

단일 HTML 파일(`index.html`)로 동작하는 커뮤니티 데모입니다. 서버 없이 브라우저에서 바로 열 수 있고,
데이터는 `localStorage`에만 저장됩니다. 같은 화면 코드 그대로 Supabase로 옮길 수 있게 데이터 레이어를 분리해 두었습니다.

## 파일

| 파일 | 설명 |
| --- | --- |
| `index.html` | 화면 + 스타일 + 스크립트 전체 (외부 라이브러리 없음) |
| `supabase-schema.sql` | Supabase SQL Editor에 그대로 실행하는 스키마 (테이블 5개 + 뷰 + RLS 정책 + 트리거) |

## 바로 열어 보기

`index.html`을 브라우저로 열면 됩니다. (모바일 크롬·사파리에서도 동일하게 동작)

1. 글 목록은 로그인 없이 읽을 수 있습니다.
2. **회원가입** → 아이디 / 닉네임 / 이메일 / 비밀번호(6자 이상) 입력
3. **첫 번째로 가입한 계정이 자동으로 관리자**가 되고, 남의 글·댓글도 삭제할 수 있습니다.
4. 글쓰기 → 댓글 → 답글 → 개추/비추를 눌러 보세요.
5. 처음 상태로 되돌리려면 푸터의 **데모 데이터 초기화**.

> 데모 계정·글은 이 브라우저의 `localStorage`에만 저장됩니다. 초기화하면 다시 시드 데이터로 채워집니다.
> 비밀번호는 데모용으로 SHA-256(솔트) 해시만 저장하며, 실제 서비스에는 Supabase Auth를 쓰세요.

## 기능

- 갤러리 4개: 자유 / 게임 / 축구 / 질문·정보
- **전체글 / 개념글**(추천 10개 이상) 필터, 제목·글쓴이·제목+내용 검색
- 글쓰기: 갤러리 선택, 말머리(일반/질문/정보/뉴스/후기), 제목(80자), 본문(10,000자)
- 글 상세: 조회수, **개추 / 비추**(같은 버튼 다시 누르면 취소, 반대 버튼은 전환)
- 댓글 + 대댓글(1단계), 작성자 본인·관리자 삭제
- 비로그인 상태에서 글쓰기·댓글·추천을 누르면 로그인/회원가입 모달
- 반응형: PC 표 형태 ↔ 모바일 카드형 목록, 하단 고정 글쓰기 버튼

## Supabase로 옮기기

1. Supabase 프로젝트를 만들고 `supabase-schema.sql` 전체를 SQL Editor에서 실행합니다.
2. Authentication → Providers → Email 을 켭니다. **"Confirm email"을 켜면** 가입 시 인증 메일을 보내고 링크를 눌러야 가입이 완료됩니다(권장). 꺼 두면 가입 즉시 로그인됩니다.
3. `index.html`의 `</body>` 앞에 supabase-js를 추가합니다.
   ```html
   <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
   ```
4. 같은 파일 안 `CONFIG`를 채웁니다.
   ```js
   const CONFIG = {
     backend: 'supabase',
     supabaseUrl: 'https://<project>.supabase.co',
     supabaseAnonKey: '<anon public key>',
     ...
   };
   ```
5. 끝입니다. 화면 코드는 `LocalStore` → `SupabaseStore` 교체만으로 그대로 동작합니다.
   (두 클래스가 같은 메서드 시그니처를 쓰도록 맞춰 두었습니다.)

### 데이터 모델

```
profiles(id→auth.users, username, nickname, is_admin)
galleries(id, name, description, icon, sort_order)
posts(id, gallery_id, author_id, head, title, body, views, created_at)
comments(id, post_id, author_id, parent_id, body, created_at)
votes(post_id, user_id, value ±1)   -- PK(post_id, user_id) · 1인 1표
```

`post_list` 뷰가 추천 수·비추 수·댓글 수·개념글 여부(`is_concept`)를 계산합니다.
조회수는 `increment_post_views(id)` RPC로만 올라가고, 쓰기/삭제는 RLS로 본인·관리자만 허용됩니다.

## 이름·설정 바꾸기

- 사이트 이름은 **도훈갤**으로 넣어 두었습니다. 바꿀 때는 `index.html`에서
  `<title>`, `.logo-title`, `.logo-sub`, 푸터 문구, `document.title = ...` 문자열들, 로그인 모달의 `auth-head`를 함께 고치면 됩니다.
- 개념글 기준 추천 수: `CONFIG.conceptThreshold`(기본 10)와 `supabase-schema.sql`의 `post_list` 뷰 `(q.recommend_count >= 10)`.
- 갤러리 추가: `SEED_GALLERIES`(데모)와 `galleries` 테이블 insert(운영)에 한 줄씩 추가.
- 말머리 추가: `HEADS` 배열과 `posts.head` check 제약을 같이 수정.

## 참고

- PC는 파일을 더블클릭해 바로 열면 되고, **아이폰 사파리**에서 보려면 `file://` 대신 http(s) 주소가 필요합니다
  (예: 같은 와이파이에서 `python3 -m http.server`로 띄우거나, 위 Supabase 연동 후 정적 호스팅에 올리기).
- 데모 모드에서 비밀번호는 브라우저 안 SHA-256 해시로만 저장되며 실제 인증 용도가 아닙니다.
