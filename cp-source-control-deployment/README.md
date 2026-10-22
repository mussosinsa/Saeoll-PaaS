# CP-Source-Control 배포 (Rocky Linux 9.7)

K-PaaS 컨테이너 플랫폼 소스 컨트롤(SCM-Manager 기반 SCM-Server, Source Control API/UI)을
CP-Portal이 설치된 클러스터에 배포한다. 배포 파일은 K-PaaS 배포 패키지
`cp-source-control-deployment-v1.6.0.tar.gz`를 내려받아 `upstream/`에 풀어 사용한다
(`upstream/`과 tarball은 저장소에 커밋하지 않는다).

## 1. 사전 조건

- `cp-portal-deployment/script/deploy-cp-portal.sh`로 CP-Portal 배포 완료
  (MariaDB `cp_scm` DB, Keycloak, Harbor, `cp-portal` namespace의 TLS secret 필요)
- `kubectl`, `helm`, `wget`, StorageClass(`cp-storageclass`)
- Master Node에서 `nextcloud.k-paas.org` 접속 가능, 각 노드에서 `registry.k-paas.org` 이미지 pull 가능
- 멀티 클러스터 환경은 CP-Portal 배포 시 **Cluster1**로 지정한 클러스터에서 실행

## 2. 배포 파일 다운로드

```bash
cd ~/Saeoll-PaaS/cp-source-control-deployment/script
./fetch-cp-source-control.sh
```

다음 작업을 수행한다.

```bash
wget --content-disposition https://nextcloud.k-paas.org/index.php/s/dkfdTd6zttpi3T2/download
ls -lh
tar -xvf cp-source-control-deployment-v1.6.0.tar.gz   # → ../upstream/{script,values_orig}
```

- 다른 버전: `SC_DOWNLOAD_URL=<다운로드 URL> ./fetch-cp-source-control.sh`
- 인터넷이 막힌 경우: tarball을 복사한 뒤 `./fetch-cp-source-control.sh /path/cp-source-control-deployment-v1.6.0.tar.gz`
- 다시 실행하면 `upstream/`을 새로 풀어 덮어쓴다.

## 3. 설치

```bash
cd ~/Saeoll-PaaS/cp-source-control-deployment/script
./deploy-cp-source-control.sh 2>&1 | tee cp-source-control-deploy.log
kubectl -n cp-source-control get pods
```

- `upstream/`이 없으면 2번 다운로드를 먼저 자동 실행한다.
- `cp-portal-deployment/script/cp-portal-vars.sh`에서 `HOST_DOMAIN`, `K8S_STORAGECLASS`,
  Keycloak·MariaDB·Harbor 계정을 읽어 `upstream/script/cp-source-control-vars.sh`에 반영한다
  (패키지의 vars 파일에 해당 변수가 있을 때만 변경). 포털 vars 위치가 다르면 `PORTAL_VARS=<경로>`.
- 멀티 클러스터: `IS_MULTI_CLUSTER=Y ./deploy-cp-source-control.sh`
- 사전 점검: StorageClass, 포털 TLS secret, MariaDB, Keycloak 실행 여부
- 재실행 가능: 생성된 `upstream/values`를 지우고 다시 배포한다.
- 정상 배포 시 `cp-source-control-api`, `cp-source-control-manager`, `cp-source-control-ui` Pod가 Running
- 배포 마지막에 4번 점검 스크립트를 자동 실행한다.

## 4. 접속 주소

패키지는 ingress 두 개를 만든다. 내부 SCM 서버는 **SCM-Manager 1.x**다.

| 주소 | 용도 |
| --- | --- |
| `https://scm.<HOST_DOMAIN>` | 소스 컨트롤 화면(사용자·관리자). 평소 접속 주소 |
| `https://scm-manager.<HOST_DOMAIN>/scm/git/<저장소명>` | **git clone/push URL** (업체·Jenkins가 사용) |
| `https://scm-manager.<HOST_DOMAIN>/scm/api/rest/<리소스>.json` | SCM-Manager 1.x REST API (예: `repositories.json`) |
| `https://scm-manager.<HOST_DOMAIN>/scm/` | SCM-Manager 1.x 관리 화면(필요 시에만) |

- 관리자: 포털 관리자 계정(`admin` / 초기화한 패스워드)
- 사용자: 로그인 화면 하단 **Register**로 가입 후 로그인

### 포털 사용자와의 관계

로그인 계정은 포털과 같은 Keycloak `cp-realm` 계정이지만, **포털 사용자 생성만으로 소스 컨트롤 계정·저장소·권한이
만들어지지는 않는다.**

| 항목 | 생성 시점 |
| --- | --- |
| 소스 컨트롤 사용자(`cp_scm.SC_INSTANCE_USER`, SCM-Manager 계정) | 해당 계정으로 `scm.`에 **최초 1회 로그인** |
| git 비밀번호(clone/push) | 최초 로그인 후 **내정보 관리**에서 변경해야 사용 가능. Keycloak 비밀번호와 별개 |
| 저장소(`cp_scm.SC_REPOSITORY`) | 레파지토리 → 신규생성 (수동) |
| 저장소 권한(`cp_scm.REPO_PERMITION`) | 저장소 상세 → 참여자 추가, 쓰기/보기 (수동) |

포털의 namespace/role 할당은 저장소 권한과 무관하다. 운영 절차는
[신규 서비스 사전작업 가이드](../cp-pipeline-deployment/docs/new-service-prework-guide.md) 3장을 따른다.
- SCM-Manager 2.x의 `/api/v2`는 없다. 1.x에서 404가 나오는 것이 정상이다.
- 브라우저에서 `scm-manager.` 주소가 `ERR_TOO_MANY_REDIRECTS`이면, 같은 브라우저에서
  `scm.`·Keycloak 로그인으로 생긴 쿠키 때문이다(서버는 `curl`로 200 응답). 시크릿 창을 쓰거나
  해당 호스트 쿠키를 삭제한다. 일반 사용은 `scm.` 주소로 한다.
- 계정·저장소 권한 운영 절차: [신규 서비스 사전작업 가이드](../cp-pipeline-deployment/docs/new-service-prework-guide.md) 3장

## 5. 동작 점검

```bash
cd ~/Saeoll-PaaS/cp-source-control-deployment/script
./check-cp-source-control.sh

# 관리자 로그인까지 확인
SCM_ADMIN_PASSWORD='<관리자 비밀번호>' ./check-cp-source-control.sh

# git 접근까지 확인 (scm. 화면에서 만든 저장소 이름)
SCM_ADMIN_PASSWORD='<관리자 비밀번호>' SCM_TEST_REPO=test ./check-cp-source-control.sh

# 사용자 등록 확인 (포털 DB, 소스 컨트롤 DB, SCM-Manager 계정, 저장소 권한)
SCM_ADMIN_PASSWORD='<관리자 비밀번호>' SCM_CHECK_USER=saeoll,jenkins-vendor-a ./check-cp-source-control.sh
```

| 단계 | 정상 기준 |
| --- | --- |
| Pod | api, manager, ui 모두 Running/Ready, 재시작 3회 이하 |
| Ingress | `scm.<도메인>`, `scm-manager.<도메인>` 호스트 존재 |
| UI | `https://scm.<도메인>/` → 200 또는 redirect |
| SCM-Manager | `/scm/` → 200, `/scm/api/rest/repositories.json` 인증 없이 → **401** |
| 관리자 로그인(선택) | 같은 API 관리자 인증 → 200 |
| git(선택) | `git ls-remote https://scm-manager.<도메인>/scm/git/<저장소>` 성공 |
| 사용자(선택) | `cp_scm.SC_INSTANCE_USER`에 등록됨, SCM-Manager 계정 있음(관리자 비밀번호 지정 시). 없으면 `scm.` 최초 로그인 필요 |

읽기 전용이며 실패 항목이 있으면 `[RESULT] FAIL`, 종료 코드 1을 반환한다. 비밀번호는 환경변수로만 받고
명령행 인자로 넘기지 않는다. 수동 확인은 다음과 같다.

```bash
D=https://scm-manager.<HOST_DOMAIN>
curl -sk -o /dev/null -w '%{http_code}\n' $D/scm/api/rest/repositories.json   # 401
git -c http.sslVerify=false clone $D/scm/git/test
```

## 6. 삭제

```bash
./uninstall-cp-source-control.sh   # 패키지의 삭제 스크립트 실행, y 입력
```

StorageClass가 NFS(reclaim 정책 `Retain`)이면 PV 삭제 후에도 NFS 서버에 데이터가 남으므로 수동 정리한다.

## 참고

- [K-PaaS 소스 컨트롤 배포 가이드](https://github.com/K-PaaS/container-platform/blob/master/install-guide/source-control/cp-source-control-standalone-guide.md)
- [K-PaaS 소스 컨트롤 사용 가이드](https://github.com/K-PaaS/container-platform/blob/master/use-guide/source-control/cp-source-control-use-guide.md)
