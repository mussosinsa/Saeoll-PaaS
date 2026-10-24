# PHP 첫 배포 실습: saeoll / homepage

이 저장소의 PHP 파이프라인으로 첫 개발(dev) 배포까지 확인하는 순서다.
값은 아래 예시 기준이며, 다른 업체·앱은 이름만 바꿔 같은 순서로 진행한다.

| 항목 | 값 |
| --- | --- |
| HOST_DOMAIN | `192.168.20.151.nip.io` |
| 업체 ID (`VENDOR`) | `saeoll` → namespace `saeoll-dev`, `saeoll-prod`, Harbor 프로젝트 `saeoll` |
| 앱 이름 (`APP_NAME`) | `homepage` |
| SCM 저장소 | `saeoll-homepage` |
| 개발자 SCM 계정 | `saeoll` (쓰기) |
| Jenkins SCM 계정 | `jenkins-saeoll` (보기) |
| 개발 URL | `https://homepage-saeoll-dev.192.168.20.151.nip.io` |

```text
0 사전 점검 → 1 Jenkins PHP 이미지 → 2 베이스 이미지 → 3 업체 온보딩 → 4 SCM 계정·저장소
→ 5 소스 push → 6 Jenkins 폴더·credential·job → 7 첫 빌드 → 8 확인
```

명령은 모두 Master Node(`k8s-cp01`)의 root 기준이다.

## 0. 사전 점검

```bash
cd ~/Saeoll-PaaS && git pull
kubectl -n cp-pipeline get pods          # Jenkins 등 Running
kubectl -n cp-source-control get pods    # api, manager, ui Running
cd cp-source-control-deployment/script && ./check-cp-source-control.sh
```

## 1. PHP 지원 Jenkins 이미지 적용 (1회)

```bash
cd ~/Saeoll-PaaS/cp-pipeline-deployment/script
./build-jenkins-php-image.sh          # 마지막에 출력되는 helm upgrade 명령을 그대로 실행
kubectl -n cp-pipeline get deploy     # Jenkins Deployment 이름 확인
kubectl -n cp-pipeline exec deploy/<jenkins-deployment> -- \
  sh -c 'php -v; composer --version; buildah --version; kubectl version --client'
```

## 2. 베이스 이미지 Harbor 등록 (1회)

```bash
./mirror-base-images.sh               # php:8.3-apache, composer:2 → harbor.<도메인>/base-images
```

## 3. 업체 온보딩

```bash
./onboard-php-vendor.sh saeoll
cat ../vendors/saeoll/jenkins-credentials.txt
```

`saeoll-dev`, `saeoll-prod` namespace(quota, pull secret, TLS secret, `deployer` SA), Harbor 프로젝트
`saeoll`과 robot 계정, `../vendors/saeoll/kubeconfig-{dev,prod}`가 만들어진다.

## 4. SCM 계정과 저장소

1. **Jenkins용 계정**: Keycloak 관리 콘솔(`https://keycloak.192.168.20.151.nip.io/admin`) → realm `cp-realm`
   → Users → Add user `jenkins-saeoll` → Credentials에서 비밀번호 설정(**Temporary 끔**)
2. `jenkins-saeoll`로 `https://scm.192.168.20.151.nip.io` **최초 로그인** → 내정보 관리에서 **git 비밀번호 변경**
   (로그아웃 후 다음 단계 진행. 시크릿 창 사용 권장)
3. `saeoll` 계정도 `scm.`에 로그인한 적이 있고 git 비밀번호를 변경했는지 확인
4. **저장소 생성**: `scm.` 화면 → 레파지토리 목록 → **➕ 나의 레파지토리** 또는 **신규생성**
   → 이름 `saeoll-homepage`, 유형 Git (일반 사용자로 안 되면 `admin`으로 생성)
5. **참여자**: 저장소 상세 → 참여자 → `saeoll` **쓰기 권한**, `jenkins-saeoll` **보기 권한**

> SCM-Manager 관리 화면(`scm-manager.../scm/`)에서 직접 만든 저장소·권한은 K-PaaS 화면에 나오지 않으므로
> 저장소와 참여자는 반드시 `scm.` 화면에서 관리한다.

확인:

```bash
cd ~/Saeoll-PaaS/cp-source-control-deployment/script
SCM_ADMIN_PASSWORD='<scmadmin 비밀번호>' SCM_CHECK_USER=saeoll,jenkins-saeoll \
  SCM_TEST_REPO=saeoll-homepage ./check-cp-source-control.sh
```

## 5. 샘플 소스 push (개발자 `saeoll`)

```bash
cd ~ && git -c http.sslVerify=false clone https://scm-manager.192.168.20.151.nip.io/scm/git/saeoll-homepage
cd saeoll-homepage
cp -r ~/Saeoll-PaaS/cp-pipeline-deployment/php-sample/. .
sed -i -e "s/defaultValue: 'vendor-a'/defaultValue: 'saeoll'/" \
       -e "s/defaultValue: 'php-sample'/defaultValue: 'homepage'/" \
       -e "s/defaultValue: '192.168.40.216.nip.io'/defaultValue: '192.168.20.151.nip.io'/" Jenkinsfile
grep -n "defaultValue" Jenkinsfile | head -4     # saeoll / homepage / 192.168.20.151.nip.io 확인

git config user.name saeoll && git config user.email saeoll@example.com
git add . && git commit -m "init php homepage"
git -c http.sslVerify=false push origin HEAD:main
git -c http.sslVerify=false push origin HEAD:develop
# Username: saeoll / Password: 내정보 관리에서 바꾼 git 비밀번호
```

## 6. Jenkins 설정 (운영 관리자)

### 6-0. 스크립트로 한 번에 등록 (권장)

폴더 `saeoll`, credential 4개, job `homepage-dev`·`homepage-prod`를 Jenkins REST API로 등록한다.
port-forward는 스크립트가 직접 열고 닫는다. 다시 실행하면 credential과 job을 갱신한다.

```bash
cd ~/Saeoll-PaaS/cp-pipeline-deployment/script
DRY_RUN=1 SCM_PASSWORD=x ./register-php-jenkins-job.sh saeoll homepage      # 생성될 XML 미리보기
JENKINS_USER=<Jenkins 관리자> JENKINS_PASSWORD='<비밀번호 또는 API 토큰>' \
  SCM_PASSWORD='<jenkins-saeoll git 비밀번호>' ./register-php-jenkins-job.sh saeoll homepage
```

- 저장소 이름이 `<업체>-<앱>`과 다르면 세 번째 인자로 지정한다(`... saeoll homepage my-repo`).
- Jenkins가 로그인 없이 관리 가능한 상태면 `JENKINS_USER`/`JENKINS_PASSWORD`는 생략한다.
- 필수 플러그인(cloudbees-folder, workflow-job, workflow-cps, git, credentials, plain-credentials,
  pipeline-input-step)이 없으면 등록 전에 중단한다.
- 운영 job 실행 권한 제한은 Jenkins 보안 설정에서 별도로 한다.

스크립트를 쓰지 않을 때는 아래 6-1, 6-2를 화면에서 진행한다.

```bash
kubectl -n cp-pipeline port-forward svc/cp-pipeline-jenkins-service 8080:8080
# 다른 PC에서 접속할 때: ... port-forward --address 0.0.0.0 svc/cp-pipeline-jenkins-service 8080:8080
```

브라우저 `http://localhost:8080` (또는 `http://<Master IP>:8080`).

### 6-1. 폴더와 credential

New Item → **Folder** `saeoll` → 폴더 → Credentials → (folder) Global → Add Credentials:

| ID | 종류 | 값 |
| --- | --- | --- |
| `saeoll-harbor-robot` | Username with password | `../vendors/saeoll/harbor-robot.env`의 `HARBOR_ROBOT_USER` / `HARBOR_ROBOT_SECRET` |
| `saeoll-kubeconfig-dev` | Secret file | `../vendors/saeoll/kubeconfig-dev` |
| `saeoll-kubeconfig-prod` | Secret file | `../vendors/saeoll/kubeconfig-prod` |
| `saeoll-scm` | Username with password | `jenkins-saeoll` / 4-2에서 바꾼 git 비밀번호 |

### 6-2. 개발 job `homepage-dev`

폴더 `saeoll` → New Item → `homepage-dev` → **Pipeline**

| 항목 | 값 |
| --- | --- |
| Build Triggers | Poll SCM `H/5 * * * *` |
| Definition | Pipeline script from SCM → Git |
| Repository URL | `http://cp-source-control-manager-service.cp-source-control.svc.cluster.local:8080/scm/git/saeoll-homepage` |
| Credentials | `saeoll-scm` |
| Branch Specifier | `*/develop` |
| Script Path | `Jenkinsfile` |

Jenkins는 클러스터 안에서 동작하므로 **서비스 주소(http)**로 clone한다. 사설 인증서 검증 오류
(`SSL certificate problem`)와 외부 ingress 경유를 피할 수 있다. 외부 주소를 쓰려면
`https://scm-manager.192.168.20.151.nip.io/scm/git/saeoll-homepage`를 쓰고 Jenkins에 CA를 등록해야 한다.

## 7. 첫 빌드

`saeoll/homepage-dev` → **Build Now**. 첫 실행에서 Jenkinsfile 파라미터가 job에 등록되고, 이후에는
**Build with Parameters**와 Poll SCM(develop push 후 5분 이내)으로 실행된다.

단계: Prepare → Composer install → Lint & Test → Build image → Push to Harbor → Deploy → Smoke test

## 8. 확인

```bash
kubectl -n saeoll-dev get deploy,pod,svc,ingress
curl -sk https://homepage-saeoll-dev.192.168.20.151.nip.io/healthz.php
```

- Harbor: `https://harbor.192.168.20.151.nip.io` → Projects → `saeoll` → `homepage:dev-<commit>-<빌드번호>`
- 브라우저: `https://homepage-saeoll-dev.192.168.20.151.nip.io`

## 자주 나는 오류

| 단계 | 메시지 | 조치 |
| --- | --- | --- |
| SCM checkout | `Authentication failed` | `saeoll-scm`의 비밀번호가 Keycloak 비밀번호인지 확인 → `scm.` 내정보 관리에서 바꾼 git 비밀번호로 교체, `jenkins-saeoll` 보기 권한 확인 |
| SCM checkout | `SSL certificate problem` | Repository URL을 6-2의 서비스 주소(http)로 변경 |
| Composer install | `php: not found` | 1단계 Jenkins PHP 이미지 미적용 |
| Build image | `manifest unknown` (base-images) | 2단계 베이스 이미지 등록 |
| Push to Harbor | `unauthorized` | `saeoll-harbor-robot` 값 확인, Harbor 프로젝트 `saeoll` 존재 확인 |
| Deploy | `forbidden` / `exceeded quota` | `saeoll-kubeconfig-dev` 파일 확인, `kubectl -n saeoll-dev describe resourcequota` |
| Smoke test | `Could not resolve host` / 404 | `kubectl -n saeoll-dev get ingress`, Pod 로그 확인 |

운영(prod) 배포와 롤백은 [신규 서비스 사전작업 가이드](new-service-prework-guide.md) 6장과
[PHP 업체별 배포 가이드](php-vendor-deploy-guide.md)를 따른다. 온보딩이 끝나면 `../vendors/saeoll/` 파일은
안전한 곳에 보관하거나 삭제한다.
