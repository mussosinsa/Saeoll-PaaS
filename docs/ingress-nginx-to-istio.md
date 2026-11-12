# ingress-nginx → Istio ingress gateway 전환 가이드 (초보자용)

ingress-nginx는 2026년 3월로 개발이 끝나(retire) 보안 패치가 더 나오지 않는다. 이 가이드는 K-PaaS 전체
(포털·Keycloak·Harbor·OpenBao·ChartMuseum·소스 컨트롤·파이프라인)와 CI/CD 포털, 업체 앱의 화면 주소를
**Istio ingress gateway**로 옮긴다. 주소(도메인·IP)는 그대로이고, **끊기는 시간은 전환 순간 약 1분**이다.
문제가 생기면 명령 하나로 되돌린다.

```
지금                                         전환 후
*.도메인 → IP ─► ingress-nginx ─► Ingress    *.도메인 → 같은 IP ─► istio-ingressgateway ─► Gateway cp-gateway ─► VirtualService
                                                                    (Ingress 는 그대로 두고, 그 내용을 VirtualService 로 바꿔 쓴다)
```

| 도구 (`~/Saeoll-PaaS/gateway/`) | 하는 일 |
|---|---|
| `install-istio-gateway.sh` | Istio(istiod)와 `istio-ingressgateway` 설치, 인증서 복사, Gateway `cp-gateway` 생성 |
| `ingress-to-istio.sh` | 클러스터의 Ingress를 읽어 VirtualService로 변환 (미리보기 → 적용 → 점검). 다시 실행해도 된다 |
| `switch-ingress-ip.sh` | ingress-nginx의 IP를 게이트웨이로 옮기기 / 되돌리기 / ingress-nginx 정지 |

모든 명령은 **관리 노드에서 root**로 실행한다. 📁는 실행 위치다.

---

## 0. 무엇이 어떻게 바뀌나

| ingress-nginx 설정 | 전환 후 |
|---|---|
| Ingress의 경로, 정규식 경로 + `rewrite-target` (CP-Portal `/cpapi/(.*)` 등) | VirtualService 경로 + rewrite (nginx 동작을 그대로 흉내 내 검사한 뒤 변환) |
| `proxy-read/send-timeout` | 경로별 `timeout` |
| `proxy-body-size`, 버퍼링 끄기, 버퍼 크기 | 할 일 없음 (Envoy는 그대로 흘려보낸다) |
| `ssl-redirect` | Gateway의 http → https 이동 |
| `backend-protocol: HTTPS` | DestinationRule (TLS) |
| 세션 고정 (`affinity: cookie`) | DestinationRule (cookie 해시) |
| `whitelist-source-range`, `auth-*`, `*-snippet`, `canary` 등 | **자동 변환 안 함** — 미리보기 보고서에 `[WARN]`으로 나온다. 쓰고 있으면 따로 상담 |
| 인증서 `cp-portal/<도메인>-tls` | `istio-system/<도메인>-tls`로 복사 (Gateway는 자기 네임스페이스의 Secret만 읽는다) |

업무 Pod에는 Istio 사이드카를 넣지 않는다. 게이트웨이만 Istio다.

---

## 1. 준비 (전환 하루 전)

📁 아무 곳

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller        # EXTERNAL-IP = 지금 주소 (예: 192.168.20.151)
kubectl get ingress -A                                           # 옮길 Ingress 목록
kubectl get ipaddresspools.metallb.io -A                         # MetalLB 주소 풀
command -v helm python3 curl
```

| 확인 | 기준 |
|---|---|
| 임시 IP 하나 | MetalLB 풀 안의 **비어 있는 IP** (예: 192.168.20.152). 전환 전까지 게이트웨이가 쓴다 |
| 노드 여유 | 게이트웨이 2개 × 약 0.1 CPU·128Mi, istiod 약 0.5 CPU·2Gi |
| 이미지 | 인터넷 환경: `docker.io/istio/pilot`, `docker.io/istio/proxyv2` (1.27.3). 폐쇄망: Harbor에 올리고 `ISTIO_HUB=harbor.<도메인>/mirror/docker.io/istio` |
| 공지 | 전환 순간 **약 1분** 모든 화면이 끊긴다. 작업 시간을 정해 알린다 |

저장소를 최신으로:

```bash
cd ~/Saeoll-PaaS && git pull origin claude/stoic-edison-jc393z
```

---

## 2. Istio 게이트웨이 설치 (임시 IP, 서비스 영향 없음)

📁 `~/Saeoll-PaaS/gateway`

```bash
cd ~/Saeoll-PaaS/gateway && ./install-istio-gateway.sh --ip 192.168.20.152
```

✅ 마지막에 `[OK] Gateway address: 192.168.20.152`, `[OK] Gateway istio-system/cp-gateway: *.<도메인>`이 나온다.

- 이미 Istio가 있으면 istiod와 게이트웨이는 그대로 둔다(`already installed - kept`).
- 이미 `cp-gateway`가 있으면 바꾸지 않고 그 hosts를 보여 준다. hosts가 `*.<도메인>`을 포함해야 한다.

---

## 3. VirtualService 만들기 (서비스 영향 없음)

**3-1. 미리보기** — 아무것도 바꾸지 않는다.

```bash
./ingress-to-istio.sh
```

호스트마다 경로가 어디로 가는지 보여 준다. 예:

```
  portal.<도메인>  (cp-portal/portal-..., from cp-portal/cp-portal-ingress)
      prefix /cpapi/        -> cp-portal-api-service.cp-portal:3333  rewrite /
      prefix /cpmigui/      -> cp-portal-migration-ui-service.cp-portal:8097
      prefix /              -> cp-portal-ui-service.cp-portal:8090
```

`[WARN] ... is not converted`가 있으면 그 Ingress가 특별한 nginx 기능을 쓰는 것이다. 내용을 확인한다(8장).
전체 결과 파일: `~/Saeoll-PaaS/gateway/out/ingress-to-istio.json`

**3-2. 적용**

```bash
./ingress-to-istio.sh --apply
```

✅ `TLS secret istio-system/<도메인>-tls`, `applied: ...`가 나온다.

---

## 4. 임시 IP로 시험 (서비스 영향 없음)

```bash
./ingress-to-istio.sh --verify --ip 192.168.20.152
```

✅ 모든 주소가 `-> 200` / `302` / `401` 등으로 나오고 마지막 줄이 `all addresses answer through 192.168.20.152`.

| 결과 | 뜻 |
|---|---|
| `404` | 그 경로에 맞는 VirtualService가 없다 → 3-1 미리보기 확인 |
| `503` | 대상 Pod/Service가 준비되지 않았다 |
| `000` | 인증서나 연결 문제 → `kubectl -n istio-system get secret <도메인>-tls` |

**브라우저 시험** (권장): PC의 hosts 파일(Windows `C:\Windows\System32\drivers\etc\hosts`)에 잠시 넣는다.

```
192.168.20.152  portal.<도메인> keycloak.<도메인> harbor.<도메인> cicd.<도메인> jenkins.<도메인> argocd.<도메인>
```

포털 로그인(SSO) → 메뉴 몇 개, Harbor 로그인, CI/CD 콘솔 로그인을 확인하고 hosts 줄을 지운다.
(nip.io 도메인은 hosts 파일이 안 먹으므로 `--verify` 결과로 판단한다.)

---

## 5. 전환 (약 1분 끊김)

```bash
./switch-ingress-ip.sh to-istio
```

확인 질문에 **지금 주소**(예: `192.168.20.151`)를 입력한다. 스크립트가 차례로:

1. ingress-nginx 서비스와 게이트웨이 설정을 `gateway/state/`에 백업
2. ingress-nginx 서비스를 ClusterIP로 바꿔 주소를 놓음 (Pod는 그대로 — 되돌리기용)
3. 게이트웨이가 같은 주소를 받음 (못 받으면 **자동으로 되돌린다**)
4. 모든 주소 점검 (`--verify`)

✅ `gateway istio-system/istio-ingressgateway: 192.168.20.151`, `all addresses answer through 192.168.20.151`.
브라우저로 포털·Keycloak·Harbor·CI/CD 콘솔 로그인을 확인한다.

> **DNS 도메인이고 MetalLB가 아닌 경우**: 주소를 옮기지 말고, DNS의 `*.<도메인>` 레코드를 게이트웨이 주소로 바꾼다
> (전날 TTL을 300초로 낮춰 둔다). 되돌리기도 DNS로 한다.

**되돌리기** (문제가 있으면 바로):

```bash
./switch-ingress-ip.sh to-nginx
```

---

## 6. 같은 날: 포털 설정과 CI/CD 포털 정리

**6-1. K-PaaS 재설치 때 ingress-nginx를 다시 깔지 않게** — `cp-portal-deployment/script/cp-portal-vars.sh`:

```bash
CP_EXPOSE="istio"
```

이후 `deploy-cp-portal.sh`는 ingress-nginx 대신 게이트웨이를 확인·설치하고, 차트를 설치할 때마다
VirtualService를 자동으로 만든다.

**6-2. CI/CD 포털을 게이트웨이 전용 방식으로** (Ingress 대신 직접 VirtualService):

📁 `~/Saeoll-PaaS/cicd-portal-deployment/script`

```bash
CICD_EXPOSE=istio ./deploy-cicd-portal.sh keycloak jenkins gitlab argocd console    # 설치한 것만
```

```bash
cd ~/Saeoll-PaaS/gateway && ./ingress-to-istio.sh --apply --prune                 # 변환본 중 원본이 사라진 것 정리
```

**6-3. 업체 앱** — 업체마다:

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script && CICD_EXPOSE=istio ./app-expose.sh <업체>
```

dev는 몇 분 안에, prod는 다음 prod Sync 때 바뀐다. 그 뒤 `./ingress-to-istio.sh --apply --prune`을 한 번 더 실행한다.
(그 전까지는 3장의 변환본이 앱 주소를 계속 열어 두므로 끊기지 않는다.)

> 6-2와 6-3은 급하지 않다. 3장의 변환본으로도 모두 동작한다. 다만 CI/CD 포털과 새 앱은 6-2 이후로 맞춰야
> 앞으로 만드는 앱이 Ingress가 아닌 VirtualService로 생긴다.

---

## 7. 1~2주 뒤: ingress-nginx 정리

```bash
cd ~/Saeoll-PaaS/gateway && ./switch-ingress-ip.sh stop-nginx              # 먼저 정지(replicas 0)만
```

다시 1~2주 문제가 없으면 삭제:

```bash
kubectl delete -f ~/Saeoll-PaaS/applications/ingress-nginx-1.13.3/deploy.yaml
```

- RKE2 내장 `rke2-ingress-nginx`를 쓰지 않으면 `/etc/rancher/rke2/config.yaml`에 `disable: [rke2-ingress-nginx]`를 넣고 rke2를 재시작한다.
- Ingress 객체는 지우지 않는다. 차트가 계속 만들고, `ingress-to-istio.sh`의 원본이 된다.

---

## 8. 앞으로 할 일 (운영)

| 언제 | 할 일 |
|---|---|
| K-PaaS 구성 요소 설치·업그레이드 (소스 컨트롤, 파이프라인, Harbor 차트 등) | `cd ~/Saeoll-PaaS/gateway && ./ingress-to-istio.sh --apply --prune` (`deploy-cp-portal.sh`는 `CP_EXPOSE=istio`면 자동) |
| 인증서 갱신 | `./ingress-to-istio.sh --apply` (갱신된 `<도메인>-tls`를 `istio-system`으로 다시 복사) |
| 새 업체 앱 | 할 일 없음 (앱 추가가 VirtualService를 만든다) |
| 주소 점검 | `./ingress-to-istio.sh --verify` |
| 접근 로그 | `kubectl -n istio-system logs deploy/istio-ingressgateway --tail=50` |

## 9. 새로 설치하는 클러스터

처음부터 ingress-nginx 없이 설치하려면 `cp-portal-vars.sh`에 `CP_EXPOSE="istio"`를 넣고 평소대로
`./deploy-cp-portal.sh`를 실행한다(`INGRESS_LB_IP` 또는 `<IP>.nip.io`의 IP가 게이트웨이 주소가 된다).
소스 컨트롤·파이프라인 설치 뒤에는 `./ingress-to-istio.sh --apply`, CI/CD 포털은 자동(`CICD_EXPOSE=auto`)이다.

## 10. 문제 해결

| 증상 | 확인 |
|---|---|
| `install-istio-gateway.sh`: `got <IP>, not <IP>` | 임시 IP가 MetalLB 풀 안에 있고 비어 있는지 (`kubectl get svc -A | grep <IP>`) |
| 게이트웨이 Pod `ImagePullBackOff` | 인터넷 또는 `ISTIO_HUB` (폐쇄망) |
| 미리보기 `[WARN] annotation ... is not converted` | 그 기능(접근 IP 제한, 인증, snippet)이 꼭 필요한지 확인. IP 제한은 Istio AuthorizationPolicy로 따로 만든다 |
| 미리보기 `[INFO] ...: VirtualService ... exists - kept` | 그 호스트는 이미 다른 VirtualService가 연다 (예: CI/CD 포털). 정상 |
| `--verify` 404 | 해당 경로의 Ingress 확인 → `./ingress-to-istio.sh` 미리보기 |
| 전환 뒤 로그인만 실패 | Keycloak 주소 `https://keycloak.<도메인>/realms/cp-realm` 확인, 브라우저 캐시·쿠키 삭제 |
| 큰 업로드(Harbor push, 콘솔 이미지)만 끊김 | 게이트웨이 앞 방화벽/L4의 시간 제한, VirtualService `timeout` |
| 무엇이든 크게 잘못됨 | `./switch-ingress-ip.sh to-nginx` (1분 안에 원래대로) |
