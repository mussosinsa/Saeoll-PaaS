# Rocky Linux 9.7 CP-Portal 배포 가이드

이 문서는 **Rocky Linux 9.7** 관리 노드에서 Kubernetes 클러스터 구성을 마친 뒤
CP-Portal 단일 클러스터 구성을 배포하는 절차를 설명한다. 배포 스크립트는 실행 시
`/etc/os-release`를 검사하므로 다른 운영체제 또는 다른 Rocky Linux 버전에서는
중단된다.

> 이 디렉터리의 스크립트는 상대 경로를 사용한다. 아래와 같이 반드시 해당
> `script` 디렉터리로 이동한 후 실행한다.

## 1. 사전 조건

- 모든 Kubernetes 노드와 배포 관리 노드: Rocky Linux 9.7
- 동작 중인 Kubernetes 클러스터와 `kubectl`용 kubeconfig
- 기본 StorageClass 또는 사용할 StorageClass
- ingress-nginx 컨트롤러와 외부에서 접근 가능한 Ingress IP
- 관리 노드에서 Kubernetes API, OCI 레지스트리, Helm/Istio 다운로드 주소에 대한
  네트워크 연결
- 비밀번호 없는 `sudo` 또는 배포 중 sudo 암호를 입력할 수 있는 계정
- 포털 호스트 이름(`portal`, `harbor`, `keycloak`, `openbao`, `chartmuseum`)이
  Ingress IP로 해석되는 DNS 또는 `nip.io` 도메인

클러스터 상태와 StorageClass를 먼저 확인한다.

```bash
kubectl cluster-info
kubectl get nodes -o wide
kubectl get storageclass
kubectl -n ingress-nginx get pods,svc
```

모든 노드는 `Ready`여야 한다. 사용할 StorageClass가 `cp-storageclass`가 아니면
아래 변수 파일의 `K8S_STORAGECLASS`를 실제 이름으로 변경한다.

## 2. Rocky Linux 도구 설치

도구 설치 스크립트는 `dnf`로 Podman, CA 인증서, `envsubst`, `uuidgen` 등 필요한
패키지를 설치하고 kubectl, Helm, step CLI, istioctl을 설치한다. 이미 설치된
패키지와 명령은 `[SKIP]` 메시지를 출력하고 다시 설치하지 않는다.

```bash
cd /workspace/Saeoll-PaaS/cp-portal-deployment/istio_mc
chmod +x install_tools.sh
./install_tools.sh
```

단일 클러스터 배포에서도 이 스크립트를 도구 설치 용도로 사용할 수 있다. 설치를
확인한다.

```bash
kubectl version --client
helm version
podman version
step version
```

## 3. 배포 변수 설정

Kubernetes HA 설치에 사용한 `cluster.env`가 있으면 다음 명령으로 포털 변수를
자동 설정한다.

```bash
cd /workspace/Saeoll-PaaS/cp-portal-deployment/script
chmod +x configure-from-cluster-env.sh
./configure-from-cluster-env.sh /path/to/cluster.env
```

자동 설정 스크립트의 매핑은 다음과 같다.

| `cluster.env` | `cp-portal-vars.sh` | 예시 결과 |
| --- | --- | --- |
| `CONTROL_PLANE_VIP` | `K8S_MASTER_NODE_IP` | `192.168.20.150` |
| `CONTROL_PLANE_VIP` + `HAPROXY_PORT` | `K8S_CLUSTER_API_SERVER` | `https://192.168.20.150:8443` |
| `DEFAULT_STORAGE_CLASS` | `K8S_STORAGECLASS` | `nfs-client` |
| `METALLB_POOL`의 첫 IP | `HOST_DOMAIN` | `192.168.20.155.nip.io` |

다른 DNS 도메인을 사용할 때는 두 번째 인자로 전달한다.

```bash
./configure-from-cluster-env.sh /path/to/cluster.env portal.example.com
```

현재 CP-Portal chart에는 온프레미스 IaaS 유형이 없으므로 기본 호환 값은 AWS(`1`)를
사용한다. 다른 유형이 필요하면 `CP_PORTAL_IAAS_TYPE=2`처럼 지정한다. 스크립트는
변경 전 파일을 `cp-portal-vars.sh.bak.<timestamp>`로 백업하며 현재 kubeconfig의 API
주소와 StorageClass도 가능한 경우 확인한다.

```bash
CP_PORTAL_IAAS_TYPE=2 \
  ./configure-from-cluster-env.sh /path/to/cluster.env
```

자동 설정 후 비밀번호와 인증 관련 값은 직접 편집한다.

```bash
cd /workspace/Saeoll-PaaS/cp-portal-deployment/script
vi cp-portal-vars.sh
```

최소한 다음 값을 환경에 맞게 설정한다.

| 변수 | 설명 | 예시 |
| --- | --- | --- |
| `K8S_MASTER_NODE_IP` | 외부에서 접근 가능한 Kubernetes API 주소의 IP | `192.168.20.10` |
| `K8S_CLUSTER_API_SERVER` | Kubernetes API URL | `https://192.168.20.10:6443` |
| `K8S_STORAGECLASS` | PVC에 사용할 StorageClass | `cp-storageclass` |
| `HOST_CLUSTER_IAAS_TYPE` | AWS 1, OpenStack 2, Naver 3, NHN 4, KT 5 | `1` |
| `HOST_DOMAIN` | Ingress IP로 해석되는 기본 도메인 | `192.168.20.155.nip.io` |
| `REPOSITORY_PASSWORD` | Harbor 관리자 비밀번호 | 안전한 값 |
| `DATABASE_USER_PASSWORD` | 포털 DB 비밀번호 | 안전한 값 |
| `DATABASE_TERRAMAN_PASSWORD` | Terraman DB 비밀번호 | 안전한 값 |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak 관리자 비밀번호 | 안전한 값 |

운영 환경에서는 파일에 포함된 기본 비밀번호와 Keycloak client secret을 반드시
교체하고 변수 파일 권한을 제한한다.

### 이미지 공급 경로와 인증서

초기 설치에서 사용하는 이미지가 모두 내부 Harbor에서 공급되는 것은 아니다.

| 구분 | 이미지 공급처 | 인증/인증서 요구 사항 |
| --- | --- | --- |
| CP-Portal API 및 백엔드 | `registry.k-paas.org/kpaas` | 기본 설정은 anonymous pull이며 Rocky Linux 시스템의 공인 CA bundle 사용 |
| 최초 UI 기반 이미지 | `registry.k-paas.org/kpaas/cp-portal-ui` 및 `cp-portal-migration-ui` | 관리 노드의 Podman이 공인 CA로 pull |
| 인증서가 포함된 UI 이미지 | 배포 중 생성한 `harbor.<HOST_DOMAIN>/cp-portal-repository` | Harbor 계정과 자체 CA 필요 |
| Harbor/OpenBao/Chaos Mesh/ChartMuseum | 주로 `registry.k-paas.org` | 각 Kubernetes 노드가 공인 CA로 pull |
| MariaDB/Keycloak 및 일부 부가 구성 | `docker.io` | 각 Kubernetes 노드의 외부 HTTPS 접근 필요 |

배포 스크립트는 Helm chart를 `oci://registry.k-paas.org/kpaas`에서 받고, 두 UI 기반
이미지를 K-PaaS registry에서 먼저 pull한다. 이 단계에는 포털용 자체 서명 인증서가
필요하지 않다. `registry.k-paas.org`의 TLS 검증에는 Rocky Linux의
`ca-certificates`가 제공하는 공인 CA bundle을 사용한다. 사설 프록시가 HTTPS를
검사하는 환경에서만 해당 프록시의 루트 CA를 관리 노드와 모든 Kubernetes 노드에
추가해야 한다.

반면 배포 중 생성하는 인증서는 내부 Harbor, Portal, Keycloak, OpenBao,
ChartMuseum의 `*.${HOST_DOMAIN}` HTTPS용이다. 자동 생성 모드에서는 다음 파일을
구분해서 사용한다.

| 파일 | 용도 |
| --- | --- |
| `certs/ca.crt` | 관리 노드·Kubernetes 노드·UI Java truststore에 등록할 CA 인증서 |
| `certs/${HOST_DOMAIN}.crt` | Ingress TLS secret에 넣는 서버 인증서 |
| `certs/${HOST_DOMAIN}.key` | 서버 인증서의 개인 키; 외부 공유 금지 |

외부 인증서를 사용하는 `TLS_CERT_AUTO_GENERATED=N` 구성에서는 서버 인증서와 키
외에 발급 CA chain 파일을 `TLS_CA_CERT_PATH`에 반드시 지정한다. 서버 인증서를 CA
trust anchor로 대신 사용하지 않는다.

배포 전에 다음 사전 점검으로 K-PaaS registry 접근과 UI 기반 이미지 존재 여부를
확인할 수 있다.

```bash
source /workspace/Saeoll-PaaS/cp-portal-deployment/script/cp-portal-vars.sh
curl --fail --silent --show-error https://registry.k-paas.org/v2/ >/dev/null
sudo podman pull "$K_PAAS_REGISTRY/$K_PAAS_REPO/cp-portal-ui:$IMAGE_TAGS"
sudo podman pull "$K_PAAS_REGISTRY/$K_PAAS_REPO/cp-portal-migration-ui:$IMAGE_TAGS"
```

```bash
chmod 600 cp-portal-vars.sh
kubectl config current-context
kubectl auth can-i '*' '*' --all-namespaces
```

마지막 명령의 결과가 `yes`인지 확인한다.

## 4. CP-Portal 배포

```bash
cd /workspace/Saeoll-PaaS/cp-portal-deployment/script
chmod +x deploy-cp-portal.sh gen-cert.sh gen-enc-keys.sh
./deploy-cp-portal.sh 2>&1 | tee cp-portal-deploy.log
```

스크립트는 OCI Helm chart를 내려받고, 자체 서명 인증서를 생성하여 Rocky Linux의
`/etc/pki/ca-trust/source/anchors`에 등록한 뒤 OpenBao, MariaDB, Harbor,
Keycloak, ChartMuseum, Chaos Mesh와 CP-Portal을 순서대로 배포한다. 실행 중 생성된
`certs`, `values`, `secmg` 디렉터리와 `secmg/unseal-key`는 민감 정보이므로 백업
매체에서도 접근 권한을 제한한다.

### OpenBao 초기화 및 Unseal 확인

배포 스크립트는 OpenBao API를 최대 10분 동안 기다린 다음 초기화 여부를 확인한다.
처음 배포할 때만 key share 3개와 threshold 2로 초기화하고, 두 key를 제출한 뒤
`/v1/sys/seal-status`를 다시 조회하여 `sealed=false`가 확인되어야 다음 단계로
진행한다. 이미 초기화 및 unseal된 OpenBao에서는 작업을 반복하지 않는다.

초기화 응답 전체는 다음 파일에 권한 `600`으로 저장된다.

```text
/workspace/Saeoll-PaaS/cp-portal-deployment/secmg/unseal-key
```

이 파일에는 unseal key와 root token이 모두 있으므로 안전한 비밀 저장소에 즉시
백업하고 일반 백업이나 Git에 포함하지 않는다. OpenBao가 이미 초기화된 상태에서 이
파일을 잃어버리면 스크립트가 key를 재발급할 수 없으며, 원본 key 백업을 복원해야
한다.

배포 후 상태는 다음과 같이 확인한다.

```bash
curl -sk "https://openbao.${HOST_DOMAIN}/v1/sys/init"
curl -sk "https://openbao.${HOST_DOMAIN}/v1/sys/seal-status"
kubectl -n openbao get pods
```

정상 결과에는 각각 `"initialized":true`, `"sealed":false`가 포함되어야 한다.
OpenBao Pod가 재시작된 후 다시 sealed 상태가 되면 보관한 JSON의
`keys_base64`에서 서로 다른 key 두 개를 사용해 unseal한다.

```bash
export BAO_ADDR="https://openbao.${HOST_DOMAIN}"
curl -sk -H 'Content-Type: application/json' -X POST \
  --data '{"key":"<keys_base64의 첫 번째 key>"}' "$BAO_ADDR/v1/sys/unseal"
curl -sk -H 'Content-Type: application/json' -X POST \
  --data '{"key":"<keys_base64의 두 번째 key>"}' "$BAO_ADDR/v1/sys/unseal"
curl -sk "$BAO_ADDR/v1/sys/seal-status"
```

## 5. 배포 확인 및 접속

```bash
kubectl get pods -A
kubectl get ingress -A
helm list -A
kubectl -n cp-portal rollout status deployment --all --timeout=10m
curl -kI "https://portal.${HOST_DOMAIN}"
```

`kubectl get pods -A`에서 포털 관련 Pod가 `Running` 또는 완료된 Job이
`Completed`이고 rollout이 성공해야 한다. 브라우저에서 다음 주소로 접속한다.

```text
https://portal.<HOST_DOMAIN>
```

자체 서명 인증서를 사용하지 않을 경우 `cp-portal-vars.sh`의
`TLS_CERT_AUTO_GENERATED=N`, `TLS_CERT_PATH`, `TLS_KEY_PATH`를 설정한다. 접속할
클라이언트도 해당 인증서 체인을 신뢰해야 한다.

## 6. 문제 해결

```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -n 50
kubectl -n cp-portal get pods
kubectl -n cp-portal logs <pod-name> --all-containers --tail=200
podman login "harbor.${HOST_DOMAIN}"
```

- `ImagePullBackOff`: 노드가 `registry.k-paas.org` 및 배포된 Harbor에 접근 가능한지,
  image pull secret과 노드 CA trust를 확인한다.
- PVC가 `Pending`: `K8S_STORAGECLASS`가 존재하고 provisioner가 정상인지 확인한다.
- Ingress 접속 실패: DNS 또는 `/etc/hosts`, ingress-nginx 서비스의 외부 IP,
  80/443 방화벽 규칙을 확인한다.
- 인증서 오류: `trust list | grep -i "$HOST_DOMAIN"`로 관리 노드의 trust 등록을
  확인한다.

### UI Pod의 `ImagePullBackOff` 복구

`cp-portal-ui`와 `cp-portal-migration-ui`는 배포 중 생성한 인증서를 포함하도록 다시
빌드한 뒤 내부 Harbor에서 가져오는 이미지이다. 따라서 두 Pod만
`ImagePullBackOff`이면 먼저 이벤트의 실제 원인을 확인한다.

```bash
kubectl -n cp-portal get pod \
  -l 'app in (cp-portal-ui,cp-portal-migration-ui)' \
  -o custom-columns='NAME:.metadata.name,IMAGE:.spec.containers[*].image,SECRET:.spec.imagePullSecrets[*].name'

kubectl -n cp-portal describe pod \
  -l 'app in (cp-portal-ui,cp-portal-migration-ui)' \
  | sed -n '/Events:/,$p'
```

출력된 이벤트 메시지별 복구 방법은 다음과 같다.

#### `x509: certificate signed by unknown authority`

Harbor의 자체 서명 인증서를 **관리 노드뿐 아니라 모든 Kubernetes 노드**의
containerd가 신뢰해야 한다. 각 control-plane/worker 노드로 인증서를 복사한 뒤
다음을 실행한다.

```bash
sudo install -D -m 0644 \
  /workspace/Saeoll-PaaS/cp-portal-deployment/certs/ca.crt \
  /etc/pki/ca-trust/source/anchors/<HOST_DOMAIN>-ca.crt
sudo update-ca-trust extract
sudo systemctl restart containerd
sudo systemctl restart kubelet
```

각 노드에서 이미지 pull을 직접 확인한다.

```bash
sudo crictl pull \
  harbor.<HOST_DOMAIN>/cp-portal-repository/cp-portal-ui:v1.7.0
```

#### `unauthorized` 또는 `pull access denied`

Pod가 `cp-regcred`를 참조하는지 확인하고 Harbor 인증 secret을 다시 만든다.

```bash
source /workspace/Saeoll-PaaS/cp-portal-deployment/script/cp-portal-vars.sh
REPOSITORY_HOST=${REPOSITORY_URL#*://}
REPOSITORY_HOST=${REPOSITORY_HOST%%/*}

kubectl -n cp-portal delete secret "$IMAGE_PULL_SECRET" --ignore-not-found
kubectl -n cp-portal create secret docker-registry "$IMAGE_PULL_SECRET" \
  --docker-server="$REPOSITORY_HOST" \
  --docker-username="$REPOSITORY_USERNAME" \
  --docker-password="$REPOSITORY_PASSWORD"

kubectl -n cp-portal patch serviceaccount default \
  -p "{\"imagePullSecrets\":[{\"name\":\"$IMAGE_PULL_SECRET\"}]}"
```

Secret의 registry 주소는 Pod의 이미지 주소와 정확히 같아야 한다.

#### `manifest unknown` 또는 `not found`

Harbor 프로젝트에 두 이미지와 설정된 tag가 실제로 push되었는지 확인한다.

```bash
source /workspace/Saeoll-PaaS/cp-portal-deployment/script/cp-portal-vars.sh

curl -sku "$REPOSITORY_USERNAME:$REPOSITORY_PASSWORD" \
  "${REPOSITORY_URL}/v2/${REPOSITORY_PROJECT_NAME}/cp-portal-ui/tags/list"
curl -sku "$REPOSITORY_USERNAME:$REPOSITORY_PASSWORD" \
  "${REPOSITORY_URL}/v2/${REPOSITORY_PROJECT_NAME}/cp-portal-migration-ui/tags/list"
```

`IMAGE_TAGS`에 지정된 tag가 없으면 배포 로그에서 `podman build`/`podman push` 실패를
확인한다. Harbor 프로젝트는 있지만 두 repository가 비어 있는 경우 다음 복구
스크립트가 인증서를 포함한 두 UI 이미지를 다시 빌드하고 push한다. 이어서 pull
secret을 갱신하고 두 Deployment의 rollout 완료까지 확인한다.

```bash
cd /workspace/Saeoll-PaaS/cp-portal-deployment/script
chmod +x recover-ui-images.sh
./recover-ui-images.sh 2>&1 | tee recover-ui-images.log
```

복구 스크립트에는 배포 과정에서 생성된 `../certs/ca.crt`와
`../values/ui/Dockerfile.template`이 필요하다. Harbor 프로젝트 자체가 없으면 먼저
`cp-portal-repository` 프로젝트를 생성해야 한다. 수정된 기본 배포 스크립트는 이후
`podman build` 또는 `podman push`가 실패하면 포털 chart 설치로 계속 진행하지 않고
즉시 실패한다.

#### DNS 또는 연결 오류

모든 노드에서 Harbor 도메인이 MetalLB Ingress IP로 해석되고 443 포트에 연결되는지
확인한다.

```bash
getent hosts "harbor.<HOST_DOMAIN>"
curl -kv "https://harbor.<HOST_DOMAIN>/v2/"
```

수정 후 두 Deployment를 재시작하고 상태를 확인한다.

```bash
kubectl -n cp-portal rollout restart deployment/cp-portal-ui-deployment
kubectl -n cp-portal rollout restart deployment/cp-portal-migration-ui-deployment
kubectl -n cp-portal rollout status deployment/cp-portal-ui-deployment --timeout=5m
kubectl -n cp-portal rollout status deployment/cp-portal-migration-ui-deployment --timeout=5m
```

## 7. 제거

제거하면 포털 구성요소의 namespace와 PV가 삭제될 수 있으므로 먼저 데이터를
백업한다.

```bash
cd /workspace/Saeoll-PaaS/cp-portal-deployment/script
chmod +x uninstall-cp-portal.sh
./uninstall-cp-portal.sh
```

다중 클러스터 배포는 먼저 `istio_mc/istio-vars-mc.sh`와
`script_mc/cp-portal-vars-mc.sh`를 구성한 뒤 각각의 디렉터리에서
`deploy-istio-mc.sh`, `deploy-cp-portal-mc.sh` 순서로 실행한다. 두 kubeconfig
context가 올바른 클러스터를 가리키는지 실행 전에 반드시 확인한다.
