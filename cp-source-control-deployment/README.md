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

## 4. 접속

- URL: `https://scm.<HOST_DOMAIN>` (CP-Portal의 `CP_SERVICE_SOURCE_CONTROL_URL`과 동일)
- 관리자: 포털 관리자 계정(`admin` / 초기화한 패스워드)
- 사용자: 로그인 화면 하단 **Register**로 가입 후 로그인
- 계정·저장소 권한 운영 절차: [신규 서비스 사전작업 가이드](../cp-pipeline-deployment/docs/new-service-prework-guide.md) 3장

## 5. 삭제

```bash
./uninstall-cp-source-control.sh   # 패키지의 삭제 스크립트 실행, y 입력
```

StorageClass가 NFS(reclaim 정책 `Retain`)이면 PV 삭제 후에도 NFS 서버에 데이터가 남으므로 수동 정리한다.

## 참고

- [K-PaaS 소스 컨트롤 배포 가이드](https://github.com/K-PaaS/container-platform/blob/master/install-guide/source-control/cp-source-control-standalone-guide.md)
- [K-PaaS 소스 컨트롤 사용 가이드](https://github.com/K-PaaS/container-platform/blob/master/use-guide/source-control/cp-source-control-use-guide.md)
