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

원본을 백업한 후 변수를 편집한다.

```bash
cd /workspace/Saeoll-PaaS/cp-portal-deployment/script
cp cp-portal-vars.sh cp-portal-vars.sh.bak
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
