# 코드 컨벤션

## 공통

- formatter:
  - Java: Spotless 또는 google-java-format 계열 유지
  - TypeScript: Prettier 기준 유지
- lint:
  - Java: `./gradlew check`
  - React / React Native: `pnpm eslint .`
- tests:
  - Java: `./gradlew test`
  - React: `pnpm vitest run`
  - React Native: `pnpm test`
- import ordering:
  - 표준 라이브러리, third-party, app internal 순서
  - alias import와 relative import를 섞을 때는 alias 먼저
- naming:
  - React / React Native components: `PascalCase`
  - hooks: `useSomething`
  - utils and services: `camelCase`
  - Java packages: lowercase
  - Java classes: `PascalCase`
- file size or split rule:
  - React / React Native screen 파일은 300 lines 전후부터 분리 검토
  - Java service/controller는 책임이 2개 이상이면 분리 검토

## 프론트엔드

- component structure:
  - `screen/page -> feature component -> shared ui`
  - data fetching과 presentational UI는 가능하면 분리
- state management:
  - screen local state 우선
  - cross-screen state만 store로 승격
- styling rules:
  - design token 또는 공통 theme 우선
  - inline style 남용 금지
- accessibility baseline:
  - button, input, modal, navigation 요소에 label/role 확인

## 백엔드

- handler/service/repository split:
  - controller는 request/response mapping만
  - business logic은 service
  - DB access는 repository
- API error format:
  - status, code, message, timestamp 기본 유지
- validation rules:
  - request DTO validation 우선
  - domain invariant는 service 또는 domain layer에서 보장
- logging rules:
  - PII 직접 기록 금지
  - request id 또는 trace id 있으면 포함

## 데이터

- schema naming:
  - table과 column은 snake_case
  - enum은 명확한 domain 용어 사용
- migration policy:
  - destructive change는 단계 분리
  - schema-notes와 ERD 같이 갱신
- metrics naming:
  - funnel, retention, conversion 등 목적이 드러나는 이름 사용

## 피할 것

- hidden side effects
- 기능 작업 커밋 안에 관련 없는 리팩터링 섞기
- 커밋 메시지를 특별한 이유 없이 영어로만 작성하기
- dead code left after change
- broad wildcard exports without need
- backend controller에 business logic 몰아넣기
