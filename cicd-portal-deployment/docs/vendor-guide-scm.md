# CI/CD 포털 개발자 가이드 (K-PaaS SCM + Jenkins)

K-PaaS 소스 컨트롤(SCM)에 소스를 두는 **내부 팀**용 안내다. 외부 업체는 [GitLab용 가이드](vendor-guide.md)를 쓴다.

> **주의**: SCM 웹 화면(`scm.<도메인>`)은 로그인한 모든 사용자에게 모든 저장소의 파일을 보여 준다
> (git clone/push만 참여자 권한으로 제한). 외부에 공개하면 안 되는 정보는 소스에 넣지 않는다.

```text
develop push ──(5분 내 자동)──▶ Jenkins <앱>-dev: 빌드·테스트·이미지 ──▶ dev 자동 배포
main 머지 → 태그 vX.Y.Z ──▶ Jenkins <앱>-release (RELEASE_TAG) ──▶ 운영 관리자 승인 ──▶ prod 배포
```

| 항목 | 주소 |
| --- | --- |
| 소스 저장소 (웹) | `https://scm.<도메인>` |
| git 주소 | `https://scm-manager.<도메인>/scm/git/<팀>-<앱>` |
| Jenkins (빌드) | `https://jenkins.<도메인>/job/<팀>/` |
| Argo CD (배포 상태) | `https://argocd.<도메인>` |
| 서비스 | dev `https://<앱>-<팀>-dev.<도메인>` / prod `https://<앱>-<팀>.<도메인>` |

## 1. 시작하기

1. 운영 관리자에게서 계정 ID·임시 비밀번호, `ca.crt`, 담당 저장소를 받는다.
2. `https://scm.<도메인>`에 로그인(K-PaaS 계정) → 우측 상단 계정 → **내정보 관리** → **비밀번호 변경**.
   이 비밀번호가 **git 비밀번호**다(로그인 비밀번호와 별개). 변경하지 않으면 clone/push가 안 된다.
3. `https://jenkins.<도메인>`, `https://argocd.<도메인>`에 같은 K-PaaS 계정(SSO)으로 로그인해 팀 폴더·앱이 보이는지 확인한다.

## 2. PC 준비

```bash
git config --global http.https://scm-manager.<도메인>/.sslCAInfo ~/kpaas-ca.crt   # 인증서 (Windows: C:/Users/<사용자>/kpaas-ca.crt)
git config --global user.name "홍길동"
git config --global user.email "hong@example.com"
git clone -b develop https://scm-manager.<도메인>/scm/git/<팀>-<앱>    # 사용자 ID / git 비밀번호
```

SCM 저장소의 기본 브랜치는 `master`로 표시되므로 반드시 `-b develop`(또는 `-b main`)으로 받는다.

## 3. 저장소 규칙

| 파일·규칙 | 내용 |
| --- | --- |
| `Jenkinsfile` | 빌드·배포 정의. 상단의 `buildScript`, `testScript`, `buildImage`, `junitReports`만 수정 |
| `Dockerfile` | **8080 포트**, `FROM ${BASE_REGISTRY}/...` 형식 유지 |
| 헬스 체크 | `GET /healthz` 200 응답 (PHP `/healthz.php`) |
| 브랜치 | `main`(운영 기준), `develop`(dev 자동 배포), `feature/<작업명>` |
| 비밀정보 | 소스에 넣지 않음 (운영 관리자에게 요청) |

언어별 빌드 명령은 [GitLab 가이드 3-1](vendor-guide.md#3-1-언어별-기본-빌드)과 같다.

## 4. 개발·dev 배포

```bash
git checkout -b feature/login develop
# ... 개발 ...
git commit -am "로그인 화면 추가"
git checkout develop && git merge --no-ff feature/login && git push origin develop
```

`develop` push 후 5분 안에 Jenkins `<팀>/<앱>-dev`가 실행되어 dev에 배포된다.
SCM에는 MR(코드 리뷰) 기능이 없으므로 리뷰는 팀 규칙으로 진행한다.

Jenkins `<앱>-dev` → 빌드 번호 → **Console Output**에서 로그를, **Stage View**에서 단계별 결과를 본다.
실패 원인과 조치는 [GitLab 가이드 5장](vendor-guide.md#5-파이프라인-확인)과 같다(잡 이름만 Stage 이름으로 대응).

## 5. 운영 배포

1. `develop` → `main` 머지 후 태그 생성·push:
   ```bash
   git checkout main && git pull && git merge --no-ff develop
   git tag -a v1.0.0 -m "v1.0.0 최초 오픈"
   git push origin main --follow-tags
   ```
2. Jenkins `<팀>/<앱>-release` → **Build with Parameters** → `RELEASE_TAG=v1.0.0` → **Build**
   (빌드·테스트·이미지 후 운영 배포 정보가 갱신됨)
3. [GitLab 가이드 7장](vendor-guide.md#7-운영-배포-pm)의 양식으로 운영 관리자에게 배포를 요청한다(파이프라인 번호 대신 Jenkins 빌드 번호).

## 6. 롤백

| 환경 | 방법 |
| --- | --- |
| dev | 이전 커밋으로 되돌려 `develop`에 push(`git revert`), 또는 운영 관리자에게 요청 |
| prod | 운영 관리자에게 요청(대상 태그 명시) |

## 7. 문제 해결

| 증상 | 조치 |
| --- | --- |
| `git clone` 401 / Authentication failed | 내정보 관리에서 git 비밀번호 설정, 로그인 비밀번호가 아닌 git 비밀번호 사용 |
| `git clone` 403 / not found | 저장소 참여자 등록 요청 |
| `warning: remote HEAD refers to nonexistent ref` | `-b develop`으로 clone |
| Jenkins 빌드가 시작되지 않음 | 5분 대기. 계속되면 `<앱>-dev` → **Build Now**, 그래도 안 되면 운영 관리자 문의 |
| 기타 | [GitLab 가이드 9장](vendor-guide.md#9-문제-해결)의 배포·Argo CD 항목 참고 |
