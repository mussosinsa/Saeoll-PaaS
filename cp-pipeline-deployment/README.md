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

### 3-2. 배포 대상 namespace와 Jenkins credential 준비

```bash
./create-php-deployer.sh php-apps          # namespace, Harbor 프로젝트, pull secret, 전용 SA
```

생성된 `php-deployer-php-apps.kubeconfig`와 Harbor 계정을 Jenkins에 등록한다.

| Credential ID | 종류 | 값 |
| --- | --- | --- |
| `php-deployer-kubeconfig` | Secret file | 생성된 kubeconfig (등록 후 로컬 파일 삭제) |
| `harbor-credentials` | Username with password | Harbor 계정 |

ServiceAccount는 대상 namespace에만 `edit` 권한을 가진다.

### 3-3. Jenkins Pipeline job 생성

Jenkins UI는 Ingress 없이 ClusterIP로만 노출되므로 port-forward로 접속한다.

```bash
kubectl -n cp-pipeline port-forward svc/cp-pipeline-jenkins-service 8080:8080
# 브라우저: http://127.0.0.1:8080
```

1. New Item → Pipeline
2. Pipeline script from SCM → Git 저장소 URL, 브랜치, Script Path `Jenkinsfile`
3. Build with Parameters: `APP_NAME`, `TARGET_NS`, `HARBOR_HOST`, `HARBOR_PROJECT`, `APP_HOST`

### 3-4. PHP 저장소 구성

`php-sample/`을 PHP 저장소 루트에 복사해 시작한다.

| 파일 | 역할 |
| --- | --- |
| `Jenkinsfile` | composer → lint/test → buildah build/push → kubectl 배포 |
| `Dockerfile` | composer 멀티스테이지 + `php:8.3-apache`(8080 포트, `public/` DocumentRoot) |
| `k8s/app.yaml` | Deployment/Service/Ingress 템플릿 |
| `public/` | 웹 루트 (`index.php`, `healthz.php`) |

클러스터에서 Docker Hub 접근이 막혀 있으면 `php:8.3-apache`, `composer:2`를 Harbor에
복사하고 Dockerfile의 `PHP_BASE`, `COMPOSER_IMAGE` build-arg를 Harbor 경로로 바꾼다.
Laravel 등은 `public/`를 DocumentRoot로 쓰므로 그대로 사용할 수 있다.
