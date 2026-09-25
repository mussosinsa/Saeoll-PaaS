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

`cp-portal-vars.sh`에 기본 placeholder가 남아 있는 상태에서
`deploy-cp-portal.sh`를 바로 실행해도 `$HOME` 아래 5단계 이내에서 `cluster.env`를
하나만 찾으면 자동으로 위 설정을 수행한다. 파일이 다른 위치에 있거나 여러 개이면
다음처럼 정확한 경로를 지정해 배포한다.

```bash
cd /workspace/Saeoll-PaaS/cp-portal-deployment/script
CLUSTER_ENV_FILE=/실제/경로/cluster.env ./deploy-cp-portal.sh
```

자동 구성은 `cp-portal-vars.sh.bak.<timestamp>` 백업을 만든 후 현재 배포 프로세스에
새 값을 다시 로드한다. 클러스터 설정에서 알 수 없는 Harbor, MariaDB, Keycloak
비밀번호는 여전히 `cp-portal-vars.sh`에서 운영 값으로 변경해야 한다.

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

#### OpenBao Pod는 Running인데 API 대기가 반복되는 경우

`openbao-0`와 `openbao-agent-injector`가 `Running`인데
`Waiting for OpenBao API (n/120)`만 반복되면 OpenBao 자체가 시작되지 않은 것이
아니라, 설치 관리 노드에서 `https://openbao.<HOST_DOMAIN>` Ingress까지의 DNS 또는
라우팅이 아직 준비되지 않은 경우가 많다. OpenBao는 초기화 전에는 `openbao-0`이
`0/1 Running`으로 표시될 수도 있다.

수정된 배포는 초기화와 unseal을 외부 Ingress로 수행하지 않는다. 사용 가능한 로컬
포트를 자동 선택하고 다음과 같은 Kubernetes API port-forward를 백그라운드로 열어
`openbao.openbao.svc:8200`에 접속한다.

```text
http://127.0.0.1:<임시 포트> -> service/openbao.openbao:8200
```

초기화, unseal, AppRole 및 secret 설정을 마치면 tunnel을 자동으로 종료하고 원래의
`SECMG_URL`을 복원한다.

#### `unable to forward port because pod is not running. Current status=Pending`

`kubectl port-forward`는 대상 Pod가 `Pending`이면 즉시 종료된다. Helm 설치 직후에는
PVC 바인딩과 이미지 pull이 끝나지 않아 `openbao-0`이 잠시 `Pending`이므로, 스크립트는
tunnel을 열기 전에 OpenBao server 컨테이너가 실제로 `Running`이 될 때까지 최대 10분
대기한다(`Waiting for OpenBao pod (n/120): openbao-0 Pending <원인>`). sealed 상태의
OpenBao는 readiness probe가 실패하여 `0/1 Running`으로 표시되므로 Ready가 아니라
Running을 기준으로 판단한다. 대기 중 port-forward가 끊기면 Pod 상태를 다시 확인한 뒤
최대 5회(`OPENBAO_PORT_FORWARD_RESTARTS`) 재연결한다.

제한 시간 안에 Running이 되지 않거나 `ImagePullBackOff`가 약 2분 이상 지속되면
Pod/PVC/StorageClass 상태, `describe`, 최근 이벤트를 출력하고 실패한다. 주요 원인은
다음과 같다.

| 이벤트/상태 | 원인 및 조치 |
| --- | --- |
| `pod has unbound immediate PersistentVolumeClaims`, PVC `Pending` | `K8S_STORAGECLASS`의 provisioner(NFS 서버 접근, 각 노드 `nfs-utils`)를 확인 |
| `ErrImagePull`, `ImagePullBackOff` | 각 노드에서 `K_PAAS_REGISTRY` 이미지 pull(DNS, 프록시, CA) 확인 |
| `didn't match pod anti-affinity`, `untolerated taint` | control-plane taint가 없는 일반 worker 노드가 있는지 확인 |

```bash
kubectl -n openbao get pods,pvc -o wide
kubectl -n openbao describe pod openbao-0
kubectl -n openbao get events --sort-by=.lastTimestamp | tail -30
```

원인을 해결한 뒤 스크립트를 다시 실행하면 된다. OpenBao 데이터 PVC가 새로 만들어져
초기화가 다시 필요한 경우 기존 `secmg/unseal-key`는 `unseal-key.<시각>.bak`로 백업된 뒤
새 초기화 결과로 교체된다. 기존 설치 프로세스는 `Ctrl+C`로
중단한 다음 최신 스크립트로 다시 실행한다. 재실행 시 Helm release는
`upgrade --install`로 갱신되고, 생성된 values/template은 새 원본으로 갱신되며, 기존
인증서와 `secmg/unseal-key`는 보존된다.

```bash
cd /workspace/Saeoll-PaaS/cp-portal-deployment/script
./deploy-cp-portal.sh 2>&1 | tee cp-portal-deploy-resume.log
```

이미 생성된 PVC를 유지해야 하는 경우 `secmg/unseal-key`를 삭제하거나 OpenBao
namespace를 제거하지 않는다.

수동으로 서비스 접근을 확인하려면 별도 터미널에서 다음을 실행한다.

```bash
kubectl -n openbao port-forward service/openbao 18200:8200
curl -s http://127.0.0.1:18200/v1/sys/init
```

### `cp-cert-setup` Init 컨테이너 CrashLoopBackOff

`cp-cert-setup-daemonset`은 내부 Harbor CA를 각 Kubernetes 노드의 Rocky Linux trust
store에 등록한다. 먼저 실패한 init 컨테이너의 실제 메시지를 확인한다.

`openssl` 출력에 `genrsa: Extra option: "domain}.key"`가 있었다면 직접 원인은
`cp-portal-vars.sh`의 `HOST_DOMAIN="{host domain}"` 기본 placeholder를 실제 값으로
바꾸지 않은 것이다. 공백이 포함된 placeholder 때문에 인증서 파일명이 여러 shell
인자로 분리되었고, 이어서 유효하지 않은 CA가 `cp-cert-setup`에 전달된 것이다.
수정된 배포 스크립트는 Kubernetes 리소스를 만들기 전에 도메인, API 주소,
master IP, StorageClass를 검증하고 이런 설정이면 즉시 중단한다.

해당 실패 상태에서는 OpenBao 설치 전이므로 다음 순서로 정리하고 다시 실행한다.

```bash
cd /workspace/Saeoll-PaaS/cp-portal-deployment/script

# cluster.env의 CONTROL_PLANE_VIP, HAPROXY_PORT, DEFAULT_STORAGE_CLASS,
# METALLB_POOL을 이용해 실제 값을 설정한다.
./configure-from-cluster-env.sh /path/to/cluster.env

source ./cp-portal-vars.sh
printf 'HOST_DOMAIN=%s\nAPI=%s\nSTORAGE=%s\n' \
  "$HOST_DOMAIN" "$K8S_CLUSTER_API_SERVER" "$K8S_STORAGECLASS"

# 실패한 초기 설치 산출물만 제거한다. OpenBao를 이미 초기화한 환경에서는
# secmg/unseal-key를 삭제하면 안 된다.
helm uninstall cp-cert-setup -n kube-system --ignore-not-found
rm -rf ../certs ../values ../secmg

./deploy-cp-portal.sh 2>&1 | tee cp-portal-deploy.log
```

제공된 HA cluster.env 예시를 사용하면 예상값은
`HOST_DOMAIN=192.168.20.155.nip.io`,
`K8S_CLUSTER_API_SERVER=https://192.168.20.150:8443`,
`K8S_STORAGECLASS=nfs-client`이다.

```bash
kubectl -n kube-system get pods -l app=cp-cert-setup -o wide
kubectl -n kube-system logs -l app=cp-cert-setup \
  -c setup --previous --prefix --tail=100
kubectl -n kube-system describe pods -l app=cp-cert-setup
```

이전 스크립트에서는 CA 등록 후 init 컨테이너 안에서 `systemctl restart containerd`가
실패하면 전체 작업이 실패했다. 수정된 값은 CA 등록과 `update-ca-trust extract`는
필수로 유지하되, init 컨테이너에서 runtime 재시작만 수행할 수 없는 경우 경고를
출력하고 완료한다. 현재 실패한 release는 다음 명령으로 갱신한다.

```bash
cd /workspace/Saeoll-PaaS/cp-portal-deployment/script
chmod +x recover-node-ca.sh
./recover-node-ca.sh 2>&1 | tee recover-node-ca.log
```

복구 스크립트는 최신 Rocky Linux용 값을 사용하여 기존 Helm release를 upgrade하고,
DaemonSet rollout을 최대 5분간 확인한다. 실패 시 Pod 상태, 이벤트 및 모든 init
컨테이너 로그를 자동 출력한다. 성공하면 UI Deployment를 다시 시작한다. 이미지
pull이 정상화된 뒤 출력된 `helm uninstall cp-cert-setup -n kube-system` 명령으로
임시 DaemonSet을 제거한다.

로그에 `Could not restart containerd` 경고가 있으면 각 Kubernetes 노드에서 한 번씩
다음을 실행한 후 UI Deployment를 다시 시작한다.

```bash
sudo update-ca-trust extract
sudo systemctl restart containerd
sudo systemctl restart kubelet

kubectl -n cp-portal rollout restart deployment/cp-portal-ui-deployment
kubectl -n cp-portal rollout restart deployment/cp-portal-migration-ui-deployment
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
