# CP-Pipeline 배포 (Rocky Linux 9.7)

K-PaaS 컨테이너 플랫폼 파이프라인(Jenkins, SonarQube, PostgreSQL, Pipeline UI/API)을
CP-Portal이 설치된 클러스터에 배포한다.

## 1. 사전 조건

- `cp-portal-deployment/script/deploy-cp-portal.sh`로 CP-Portal 배포 완료
  (MariaDB, Keycloak, Harbor, `cp-portal` namespace의 TLS secret 필요)
- `kubectl`, `helm`, 여유 메모리 4Gi 이상, StorageClass(`cp-storageclass`) 여유 28Gi 이상
- 각 노드에서 `registry.k-paas.org` 이미지 pull 가능

## 2. 설치

`cp-pipeline-vars.sh`의 `HOST_DOMAIN`을 비워 두면(`{host domain}`) 배포 스크립트가
`cp-portal-deployment/script/cp-portal-vars.sh`에서 도메인, StorageClass, Keycloak
client secret, MariaDB·Harbor 계정을 읽어 동일한 값으로 배포한다. 포털과 다른 값을
쓰려면 `cp-pipeline-vars.sh`를 직접 수정한다.

```bash
cd ~/Saeoll-PaaS/cp-pipeline-deployment/script
./deploy-cp-pipeline.sh 2>&1 | tee cp-pipeline-deploy.log
kubectl -n cp-pipeline get pods
```

- 사전 점검: StorageClass, 포털 TLS secret, MariaDB, Keycloak 실행 여부
- 재실행 가능: `helm upgrade --install`을 사용하고 `values`를 매번 새로 생성
- 접속: `https://pipeline.<HOST_DOMAIN>` (포털 관리자 계정)

삭제는 `./uninstall-cp-pipeline.sh`.

### 2-1. Jenkins 보안 (admin 비밀번호·접근 제한)

설치 후 다음을 실행한다 (재실행 가능).

```bash
./secure-cp-pipeline-jenkins.sh          # apply + 접근 확인 (check / remove)
```

K-PaaS 파이프라인 Jenkins(`cp-pipeline-jenkins`)를 점검한 결과(chart 1.6.2, 이미지 v1.6.0):

| 항목 | 결과 |
| --- | --- |
| admin 비밀번호 설정 | **배포 시 지정 불가.** chart·`cp-pipeline-vars.sh`·Secret·ConfigMap·config-server·DB에 Jenkins 계정 항목이 없다 |
| 계정 | 로그인 필수(익명 403), 사용자 `admin` 하나, 로그인한 사용자는 전체 관리자. 비밀번호는 이미지에 미리 설정된 값(`secrets/initialAdminPassword` 값과 다름) |
| API 토큰 | `admin`에 이미지 제작 시(2017) 만든 구형 API 토큰이 있다. 파이프라인 실행 중 admin 비밀번호 로그인 기록이 없어 API는 이 토큰을 쓰는 것으로 보인다 — 토큰은 지우지 않는다 |
| 버전 | Jenkins **2.46.1**(2017), 특권(privileged) 컨테이너. 인증 없이 악용 가능한 공개 취약점이 있는 버전 |
| 네트워크 | `cp-pipeline` 네임스페이스는 Kyverno 기본 NetworkPolicy 제외 대상 → 기본 상태에서는 모든 네임스페이스(업체 앱 포함)가 Jenkins에 접근 가능 |

따라서 **접근 제한이 우선**이다. 스크립트는 Jenkins Pod로 들어오는 트래픽을 `cp-pipeline` 네임스페이스(파이프라인 API·UI)로
제한한다. 관리자의 `kubectl port-forward`는 영향 없다. 적용 후 파이프라인 포털에서 파이프라인을 실행해 정상 동작을 확인한다.

admin 비밀번호 변경은 Jenkins 화면에서 가능하다(PVC에 저장되어 유지). 파이프라인 API가 비밀번호를 쓰지 않는 것으로 보이지만
확정되지 않았으므로 작업 시간에 다음 순서로 한다: `kubectl -n cp-pipeline cp <jenkins pod>:/var/jenkins_home/users ./jenkins-users-backup`
→ 변경 → 파이프라인 실행 확인 → 문제 시 `kubectl cp`로 `users`를 되돌리고 `kubectl -n cp-pipeline rollout restart deploy/cp-pipeline-jenkins-deployment`.
Jenkins 버전·토큰은 이미지에 고정되어 있어 근본 해결은 K-PaaS 이미지 갱신이 필요하다.

## 3. PHP 소스 배포

포털 파이프라인 UI의 Build job은 Java(Gradle/Maven)만 지원한다. PHP 애플리케이션은
PHP 도구를 추가한 Jenkins 이미지에서 `Jenkinsfile` 기반 Pipeline job으로 빌드/배포한다.

```text
Git(PHP 소스) → Jenkins: composer install → php -l / phpunit
             → buildah로 이미지 빌드 → Harbor push → kubectl apply → rollout 확인
```

### 3-1. PHP 지원 Jenkins 이미지 빌드

`jenkins-php/Dockerfile`은 `cp-pipeline-jenkins:v1.6.0`에 php-cli(주요 확장), Composer,
buildah, kubectl을 추가한다. 베이스 이미지 OS에 맞춰 apt/dnf/apk를 자동 선택하고,
원래 실행 사용자를 유지한다.

```bash
cd ~/Saeoll-PaaS/cp-pipeline-deployment/script
./build-jenkins-php-image.sh
```

Harbor의 public 프로젝트 `cp-pipeline`에 `cp-pipeline-jenkins-php:v1.6.0`으로 push된다.

- 신규 설치:
  ```bash
  JENKINS_IMAGE_REGISTRY=harbor.<HOST_DOMAIN>/cp-pipeline \
  JENKINS_IMAGE_NAME=cp-pipeline-jenkins-php ./deploy-cp-pipeline.sh
  ```
- 기존 설치: 스크립트가 출력하는 `helm upgrade ... --set image.registry=... --set image.name=...`
  명령을 실행한다. Jenkins 데이터는 PVC에 유지된다.

확인:
```bash
kubectl -n cp-pipeline exec deploy/cp-pipeline-jenkins-deployment -- sh -c 'php -v; composer --version; buildah --version; kubectl version --client'
```
(Deployment 이름은 `kubectl -n cp-pipeline get deploy`로 확인)

### 3-2. 업체별 관리·배포

신규 서비스의 사전작업(포털 계정, namespace·권한, SCM 계정, 베이스 이미지 Harbor 등록, 파이프라인 등록)은
[신규 서비스 배포 사전작업 및 파이프라인 사용 가이드](docs/new-service-prework-guide.md)를 따른다.
처음 한 번 전체 흐름을 확인하려면 [PHP 첫 배포 실습(saeoll/homepage)](docs/php-quickstart-saeoll.md)을 따라 한다.

Jenkins 폴더·credential·dev/prod job은 `script/register-php-jenkins-job.sh <업체> <앱>`으로 한 번에 등록할 수 있다
(`onboard-php-vendor.sh` 실행 후, `SCM_PASSWORD`와 Jenkins 계정 환경변수 필요).

업체 온보딩(`script/onboard-php-vendor.sh`), SCM 계정·저장소 권한, 개발(`develop`) 자동 배포,
운영(릴리스 태그 + 승인) 배포 절차는
[PHP 유지보수 업체별 소스 관리·배포 가이드](docs/php-vendor-deploy-guide.md)를 따른다.

### 3-3. PHP 저장소 구성

`php-sample/`을 PHP 저장소 루트에 복사해 시작한다.

| 파일 | 역할 |
| --- | --- |
| `Jenkinsfile` | composer → lint/test → buildah build/push → (prod 승인) → kubectl 배포 → smoke test |
| `Dockerfile` | composer 멀티스테이지 + `php:8.3-apache`(8080 포트, `public/` DocumentRoot) |
| `k8s/app.yaml` | Deployment/Service/Ingress(TLS) 템플릿 |
| `public/` | 웹 루트 (`index.php`, `healthz.php`) |

베이스 이미지(`php:8.3-apache`, `composer:2`)는 `script/mirror-base-images.sh`로 Harbor
`base-images` 프로젝트에 등록하고, 파이프라인이 `BASE_REGISTRY` build-arg로 Harbor 경로를 지정한다.
Laravel 등은 `public/`를 DocumentRoot로 쓰므로 그대로 사용할 수 있다.
