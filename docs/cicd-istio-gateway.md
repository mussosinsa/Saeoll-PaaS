# CI/CD 포털 — Istio Gateway로 화면 열기 (ingress-nginx 없이)

K-PaaS를 RKE2에 설치해 **ingress-nginx 없이 Istio의 `cp-gateway`** 로 포털·Keycloak을 여는 클러스터에서,
CI/CD 포털(Jenkins·GitLab·Argo CD·콘솔)과 **업체 앱 주소**도 같은 게이트웨이의 **VirtualService**로 연다.

```
브라우저 ─https─► istio-ingressgateway (LoadBalancer 192.168.10.110) ─► Gateway istio-system/cp-gateway
                                                                         ├ VirtualService cicd-jenkins/jenkins        → jenkins:8080
                                                                         ├ VirtualService cicd-gitlab/gitlab          → gitlab:80
                                                                         ├ VirtualService cicd-argocd/argocd-server   → argocd-server:80
                                                                         ├ VirtualService cicd-console/cicd-console   → cicd-console:80
                                                                         └ VirtualService <업체>-dev/<앱>              → <앱>:80 (앱마다, gitops)
```

## 1. 무엇이 바뀌나

| 항목 | ingress 방식 (기존) | istio 방식 |
|---|---|---|
| 설정 | `INGRESS_CLASS_NAME` | `CICD_EXPOSE=istio` (기본 `auto`: 게이트웨이가 있고 ingress-nginx가 없으면 자동), `ISTIO_GATEWAY=istio-system/cp-gateway` |
| Jenkins·Argo CD | 차트의 Ingress | 차트 Ingress 끔 + VirtualService |
| GitLab·콘솔 | 매니페스트의 Ingress | Ingress 빼고 적용(남아 있던 것은 삭제) + VirtualService. 시간 제한 GitLab 600초, 콘솔 1800초(이미지 업로드) |
| 앱 주소 | gitops `base/ingress.yaml` | gitops `base/virtualservice.yaml` (앱 추가가 자동 선택), Argo CD 링크(`link.argocd.argoproj.io/external-link`) 포함 |
| 앱 상태 | Ingress에 주소가 안 붙으면 Argo CD **Progressing** | VirtualService는 상태가 없어 **Healthy** |
| 세션 고정(자동 확장) | nginx cookie 주석 | `DestinationRule` (cookie `cicd-route`, 1시간) |
| 사전 점검 | IngressClass·ingress-nginx 컨트롤러 | 게이트웨이 존재, HTTPS 서버 hosts가 `jenkins.`·`gitlab.`·`argocd.`·`cicd.`·`keycloak.`을 포함하는지, 이름이 게이트웨이 주소로 풀리는지 |
| Istio API | — | 클러스터가 제공하는 버전 자동 선택(`networking.istio.io/v1`, 없으면 `v1beta1`) |

같은 게이트웨이의 VirtualService로 열기 때문에, 별도 IngressClass(`istio`)로 열 때 생기던
"포털·Keycloak과 번갈아 열면 404" 문제가 없다.

## 2. 확인할 것 (설치 전)

```bash
kubectl -n istio-system get svc istio-ingressgateway                       # EXTERNAL-IP (예: 192.168.10.110)
kubectl -n istio-system get gateways.networking.istio.io cp-gateway -o jsonpath='{.spec.servers[*].hosts}'; echo
kubectl get pods -A -l app.kubernetes.io/name=ingress-nginx                  # 없어야 auto 가 istio 를 고른다
```

- 게이트웨이 hosts가 `*` 또는 `*.<도메인>`이면 그대로 된다. 이름을 하나씩 적는 게이트웨이면 `jenkins. gitlab. argocd. cicd.`
  (+ 앱 주소 `<앱>-<업체>-dev.`, `<앱>-<업체>.`)을 추가하고, 게이트웨이 인증서도 그 이름을 포함해야 한다.
- 도메인이 `192.168.10.110.nip.io`처럼 게이트웨이 IP를 담고 있으면 DNS 등록은 필요 없다.

## 3. 설치 / 전환

📁 `~/Saeoll-PaaS/cicd-portal-deployment/script` (또는 `/data/kpaas/cicd/cicd-portal-deployment/script`)

**새로 설치**: 설정 마법사가 게이트웨이를 찾아 `istio`를 기본값으로 묻는다.

```bash
./setup-cicd-env.sh
```

마법사 없이 하려면 `cicd-vars.sh`는 그대로 두고(기본 `CICD_EXPOSE=auto`) 평소대로 설치한다. 강제하려면:

```bash
CICD_EXPOSE=istio ./deploy-cicd-portal.sh preflight
```

사전 점검에 다음이 나오면 된다:

```
[INFO] Web addresses: Istio VirtualServices on istio-system/cp-gateway (CICD_EXPOSE=auto)
[OK]   Gateway istio-system/cp-gateway: HTTPS hosts cover keycloak.…, argocd.…, cicd.…, jenkins.…, gitlab.…
[OK]   DNS: keycloak.… -> 192.168.10.110 (Istio ingress gateway)
```

**이미 설치된 포털을 전환** (손으로 만든 VirtualService가 있어도 된다 — 같은 이름으로 덮어쓴다):

```bash
./deploy-cicd-portal.sh keycloak jenkins gitlab argocd console          # 설치한 것만 (scm만: gitlab 빼기)
```

```bash
kubectl get virtualservices.networking.istio.io -A | grep cicd-          # jenkins, gitlab, argocd-server, cicd-console
kubectl get ingress -A | grep cicd-                                      # 아무것도 없어야 한다
```

> 콘솔 이미지가 이번 변경 전 것이면 `console-image console`로 새로 만들어야 콘솔에서 하는 **앱 추가**도 VirtualService를 만든다.

## 4. 업체 앱

- **새 앱**: 앱 추가(콘솔·`add-app.sh`)가 VirtualService로 만든다. 주소: `https://<앱>-<업체>-dev.<도메인>`, 운영 `https://<앱>-<업체>.<도메인>`.
- **이미 Ingress로 추가된 앱** — 업체마다 한 번:

```bash
./app-expose.sh <업체>                 # 업체의 모든 앱 (특정 앱만: ./app-expose.sh <업체> <앱> ...)
```

  gitops 저장소의 `apps/<앱>/base/ingress.yaml`을 `virtualservice.yaml`로 바꾸고 dev/prod 주소 패치를 고친다
  (자동 확장 패치 등은 그대로). dev는 몇 분 안에 자동 반영, **prod는 다음 prod Sync** 때 반영된다.
- 업체 네임스페이스가 단일(single) 구성이어도 대상 서비스(`<앱>-dev`/`<앱>-prod`)를 맞게 넣는다.
- 손으로 만든 앱 VirtualService가 있으면 같은 이름(`<앱>`)이라 Argo CD가 관리하게 된다. 다른 이름이면 지운다.

## 5. 되돌리기

`CICD_EXPOSE=ingress`(마법사에서 `ingress`)로 바꾸고 3장의 배포 명령과 `./app-expose.sh <업체>`를 다시 실행하면
Ingress로 돌아간다(이때는 ingress-nginx와 `INGRESS_CLASS_NAME`이 필요). 남은 VirtualService는 직접 지운다:

```bash
kubectl delete virtualservices.networking.istio.io -l app.kubernetes.io/part-of=cicd-portal -A
```

## 6. 문제 해결

| 증상 | 확인 |
|---|---|
| 점검 `Gateway ... hosts ... do not include` | 게이트웨이 `servers[].hosts`에 이름(또는 `*.<도메인>`) 추가, 인증서 SAN 확인 |
| 점검 `DNS: ... does not resolve` | 이름을 게이트웨이 IP로 등록 (nip.io면 도메인 오타) |
| 화면 404 | `kubectl get virtualservices.networking.istio.io -A`에 그 호스트가 있는지, 게이트웨이 이름(`ISTIO_GATEWAY`) |
| 화면 503 `no healthy upstream` | 대상 Pod/Service가 준비 전: `kubectl -n cicd-<x> get pods,svc` |
| 콘솔 이미지 업로드가 중간에 끊김 | VirtualService `cicd-console`의 `timeout: 1800s` 확인, 게이트웨이 앞 L4/VIP의 시간 제한 |
| 앱 주소 404 | 앱 gitops에 `base/virtualservice.yaml`이 있는지 → 없으면 `./app-expose.sh <업체> <앱>`, prod는 prod Sync |
