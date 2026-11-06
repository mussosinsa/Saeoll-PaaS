# 서버 초기화 후 도메인 방식으로 재설치하기

`https://portal.192.168.20.151.nip.io`처럼 **주소에 내부 IP가 드러나는 nip.io 방식**을 버리고,
서버를 모두 초기화(OS 재설치)한 뒤 **자체 도메인**(예: `https://portal.kpaas.example.co.kr`)으로 K-PaaS와 CI/CD 포털을 다시 설치하는 절차다.

| 구분 | nip.io (기존) | 도메인 (재설치 후) |
| --- | --- | --- |
| 주소·인증서 | 내부 IP 노출 (`*.192.168.20.151.nip.io`) | `*.kpaas.example.co.kr` — IP 노출 없음 |
| 이름 해석 | 외부 공용 서비스 nip.io (폐쇄망에서 동작 안 함, 조회 정보가 외부로 나감) | 기관 내부 DNS |
| 인증서 | 사설 CA | 사설 CA 또는 기관 와일드카드 인증서 |

> 도메인은 주소에서 IP를 숨기고 외부 DNS 의존을 없앤다. 접근 통제(누가 접속할 수 있는지)는 방화벽·네트워크 정책으로 따로 관리한다.

이 문서의 예시 값 — 자기 환경 값으로 바꿔 읽는다.

| 항목 | 예시 |
| --- | --- |
| 도메인 (`HOST_DOMAIN`) | `kpaas.example.co.kr` |
| Ingress IP (`INGRESS_LB_IP`, MetalLB 풀의 첫 IP) | `192.168.20.151` |
| 내부 DNS 서버 | `192.168.20.10` |
| 업체 / 앱 | `saeoll` / `php-service` |

---

## 0. 전체 순서

```text
[현재 서버]  2. 백업 (backup-before-reinstall.sh) ──> 서버 밖으로 복사
[인프라]     1. 도메인·DNS 와일드카드·인증서 준비
[모든 서버]  3. OS 재설치 → 노드 공통 설정(DNS) → Kubernetes 설치 → CoreDNS 확인
[관리 노드]  4. CP-Portal (도메인)  5. source-control → pipeline → CI/CD 포털
[관리 노드]  6. 복원 (업체 등록 → 저장소 → 앱 추가 → DB → 빌드)   7. 검증
```

---

## 1. 사전 준비 (인프라 담당)

### 1-1. 도메인과 IP 정하기

- 도메인 하나를 정한다: `kpaas.example.co.kr`. 모든 주소는 그 아래에 생긴다.
  `portal.`, `keycloak.`, `harbor.`, `openbao.`, `chartmuseum.`, `scm.`, `scm-manager.`, `pipeline.`, `cicd.`, `jenkins.`, `argocd.`, `gitlab.`
  그리고 업체 앱 `<앱>-<업체>-dev.`, `<앱>-<업체>.`
- Ingress IP: MetalLB 주소 풀(`cluster.env`의 `METALLB_POOL`)의 **첫 IP**가 ingress-nginx에 할당된다. 다른 IP를 쓰려면 설치 때 `INGRESS_LB_IP`로 지정한다.

### 1-2. DNS 와일드카드 레코드

내부 DNS 서버에 **와일드카드 A 레코드** 하나를 등록한다. 앱이 늘어도 DNS를 다시 고칠 필요가 없다.

```text
*.kpaas.example.co.kr.   IN  A   192.168.20.151
```

- BIND: 위 줄을 `example.co.kr` 존 파일에 추가하고 serial을 올린 뒤 `rndc reload`.
- Windows DNS: `example.co.kr` 영역 → 새 호스트(A) → 이름 `*.kpaas` → IP `192.168.20.151`.
- 이 DNS를 **사용자 PC(VPN 포함), 관리 노드, 모든 Kubernetes 노드**가 써야 한다.

확인 (아무 PC에서, 임의 이름까지 해석되면 와일드카드가 맞다):

```bash
nslookup portal.kpaas.example.co.kr
```

```bash
nslookup anything-test.kpaas.example.co.kr
```

### 1-3. 인증서 방식 정하기

| 방식 | 설정 | 특징 |
| --- | --- | --- |
| **A. 사설 CA (기본)** | `TLS_CERT_AUTO_GENERATED="Y"` | 설치 스크립트가 CA와 `*.kpaas.example.co.kr` 인증서를 만든다. **`ca.crt`를 사용자 PC에 배포**해야 브라우저 경고가 없다 (노드에는 설치 스크립트가 배포) |
| **B. 기관 와일드카드 인증서** | `TLS_CERT_AUTO_GENERATED="N"`, `TLS_CERT_PATH`, `TLS_KEY_PATH`, `TLS_CA_CERT_PATH` | `*.kpaas.example.co.kr` 인증서·키·발급 CA 체인 파일. 기관 PC가 이미 신뢰하는 CA면 배포 불필요 |

> 와일드카드 인증서는 한 단계만 덮는다. `*.kpaas.example.co.kr`은 `php-service-saeoll.kpaas.example.co.kr`은 되지만 `a.b.kpaas.example.co.kr`은 안 된다. 포털이 만드는 주소는 모두 한 단계라 문제없다.

---

## 2. 재설치 전 백업 (지금 서버에서, 반드시)

서버를 초기화하면 소스 저장소·DB·설정이 모두 사라진다. **초기화 전에** 관리 노드에서 실행한다.

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
```

```bash
SCM_ADMIN_PASSWORD='<SCM 관리자 git 비밀번호>' IMAGES=1 ./backup-before-reinstall.sh
```

| 백업 폴더 | 내용 |
| --- | --- |
| `inventory/` | 업체(소스 방식, 네임스페이스 방식, CI 계정, 구성원), 앱(유형, 실행 중 태그, 중지 여부) — 다시 등록할 목록 |
| `repos/` | SCM 저장소 전체(모든 브랜치·태그, git mirror), scm 참여자 목록. GitLab 업체는 그룹의 프로젝트 |
| `db/` | 앱 DB 덤프 (앱 전용 MariaDB, K-PaaS 공용 MariaDB) |
| `security/` | 품질 관리 정책(게이트, 프로파일, 예외)과 규칙 |
| `images/` | 실행 중 이미지 목록. `IMAGES=1`이면 이미지 파일(oci-archive, skopeo 필요) |
| `config/` | 각 배포의 변수 파일 (**비밀번호 포함** — 안전하게 보관) |

마지막 줄의 안내대로 **백업을 서버 밖(관리자 PC, NAS)으로 복사**한다. 종료 코드 3이면 `[WARN] Not saved:` 항목을 확인한다.

```bash
tar czf backup.tgz -C ~/Saeoll-PaaS/cicd-portal-deployment backup-<날짜>
```

추가로 직접 챙길 것:
- 외부 DB를 쓰는 앱은 그 DB에서 백업한다.
- Keycloak 사용자 계정(비밀번호 포함)은 백업하지 않는다. 재설치 후 업체 등록 화면의 **신규 계정 만들기**로 다시 만들고 임시 비밀번호를 전달한다.
- DefectDojo를 쓰고 있었다면 DefectDojo 자체 백업 절차를 따른다.

---

## 3. 서버 초기화와 OS·Kubernetes 설치

### 3-1. OS 설치 (모든 서버)

- **Rocky Linux 9.7** 최소 설치 (배포 스크립트가 버전을 검사한다).
- 고정 IP, 호스트명(`hostnamectl set-hostname master01` 등), 시간 동기화(`chronyd`)를 설정한다.

### 3-2. 노드 공통 설정 — DNS (모든 서버)

모든 노드가 내부 DNS를 쓰게 한다. (연결 이름은 `nmcli connection show`로 확인)

```bash
sudo nmcli connection modify <연결이름> ipv4.dns 192.168.20.10 ipv4.ignore-auto-dns yes
```

```bash
sudo nmcli connection up <연결이름>
```

```bash
getent hosts portal.kpaas.example.co.kr
```

`192.168.20.151`이 나와야 한다. 노드가 Harbor(`harbor.<도메인>`)에서 이미지를 받으므로 **모든 노드**에서 확인한다.

### 3-3. Kubernetes 설치와 클러스터 DNS 확인

기존과 같은 방법으로 Kubernetes(HA)를 설치한다. 설치에 쓴 `cluster.env`(`CONTROL_PLANE_VIP`, `METALLB_POOL`, `DEFAULT_STORAGE_CLASS` 등)는 4장에서 다시 쓴다.

Pod도 도메인을 해석해야 한다(Jenkins → Harbor, 콘솔 → Keycloak 등). CoreDNS는 노드의 DNS 설정을 따르므로 3-2를 했으면 보통 그대로 된다. 확인:

```bash
kubectl run dnscheck --rm -i --restart=Never --image=busybox:1.36 -- nslookup portal.kpaas.example.co.kr
```

해석되지 않으면 CoreDNS에 도메인 전달을 추가한다.

```bash
kubectl -n kube-system edit configmap coredns
```

`Corefile`의 기존 `.:53 { ... }` 블록 **아래에** 추가:

```text
kpaas.example.co.kr:53 {
    errors
    cache 30
    forward . 192.168.20.10
}
```

kubespray로 설치해 nodelocaldns를 쓰면 `upstream_dns_servers`에 내부 DNS를 넣고 설치하거나, `nodelocaldns` ConfigMap에도 같은 블록을 넣는다.

---

## 4. CP-Portal 설치 (도메인)

[CP-Portal 배포 가이드](../cp-portal-deployment/README.md)를 따르되, 변수 설정에서 **도메인을 지정**한다.

```bash
cd ~/Saeoll-PaaS/cp-portal-deployment/script
```

```bash
./configure-from-cluster-env.sh /path/to/cluster.env kpaas.example.co.kr
```

결과에 `HOST_DOMAIN=kpaas.example.co.kr`, `INGRESS_LB_IP=192.168.20.151`이 나온다. Ingress IP를 바꾸려면 앞에 `INGRESS_LB_IP=<IP>`를 붙여 실행한다.
이어서 `cp-portal-vars.sh`에서 비밀번호(Harbor, DB, Keycloak)를 설정하고, 인증서 방식 B면 `TLS_*` 값을 넣는다.

```bash
./deploy-cp-portal.sh 2>&1 | tee cp-portal-deploy.log
```

배포 스크립트는 ingress-nginx가 뜬 뒤 **DNS를 먼저 검사**한다.

```text
[OK] DNS (this node): portal.kpaas.example.co.kr -> 192.168.20.151
[OK] DNS (this node): dns-check-12345.kpaas.example.co.kr -> 192.168.20.151   ← 와일드카드 확인
[OK] DNS (cluster/CoreDNS): portal.kpaas.example.co.kr -> 192.168.20.151
```

`[ERROR] DNS ...`가 나오면 1-2(DNS 레코드), 3-2(노드 DNS), 3-3(CoreDNS)을 확인한다.
테스트 Pod 이미지(`busybox`)를 받을 수 없는 폐쇄망이면 `DNS_CHECK_IMAGE=<Harbor 미러 이미지>`를 지정하거나, 3-3을 직접 확인한 뒤 `SKIP_DNS_CHECK=1`로 실행한다.

인증서 방식 A면 설치 후 `cp-portal-deployment/certs/ca.crt`를 사용자 PC에 배포한다(신뢰할 수 있는 루트 인증 기관). **`ca.key`는 절대 배포하지 않는다.**

---

## 5. 나머지 구성 요소 설치

모두 CP-Portal의 `HOST_DOMAIN`을 그대로 읽으므로 **도메인을 다시 입력하지 않는다.**

| 순서 | 구성 요소 | 문서 |
| --- | --- | --- |
| 1 | 소스 컨트롤 (`scm.<도메인>`) | `cp-source-control-deployment/README.md` |
| 2 | 파이프라인 (필요 시) | `cp-pipeline-deployment/README.md` |
| 3 | CI/CD 포털 (Jenkins, Argo CD, 콘솔, 보안 검사) | [CI/CD 포털 처음 설치하기](../cicd-portal-deployment/docs/getting-started.md) |

CI/CD 포털 설치 후 확인: `https://cicd.kpaas.example.co.kr` 로그인, 콘솔 **시스템 점검** 성공.

---

## 6. 복원

백업을 관리 노드로 복사해 풀고, 먼저 **복원 계획**을 본다 (아무것도 바꾸지 않는다).

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script
```

```bash
./restore-after-reinstall.sh ~/backup-<날짜>
```

계획에 나온 순서대로 진행한다.

| 순서 | 할 일 | 방법 |
| --- | --- | --- |
| 1 | 업체 등록 | 콘솔 **업체 등록** — 백업과 같은 업체 ID, 소스 방식, 네임스페이스 방식. 구성원 계정은 **신규 계정 만들기**로 생성 |
| 2 | 소스 저장소 복원 | `SCM_ADMIN_PASSWORD=... ./restore-after-reinstall.sh <백업> --repos` — 저장소 생성(참여자: CI 계정 보기, 업체 구성원 쓰기) 후 모든 브랜치·태그 push. `<업체>-gitops`는 새로 만들어진 것을 쓴다 |
| 3 | 앱 추가 | 콘솔 **앱 추가** — 같은 앱 ID·유형, **시작 소스를 넣지 않음** 체크, 저장소 이름이 `<업체>-<앱>`이 아니면 **기존 SCM 저장소 이름** 입력. DB를 쓰던 앱은 같은 방식으로 **DB 연결** |
| 4 | DB 복원 | `./restore-after-reinstall.sh <백업> --db` |
| 5 | 빌드·배포 | dev: develop 빌드(자동 또는 콘솔 빌드 실행). prod: 백업의 `images/running.txt`에 있던 태그로 **릴리스** → prod Sync. 이미지 배포 앱: **컨테이너 이미지 등록**에 `images/*.tar` 업로드 |
| 6 | 품질 관리 정책 | `./restore-after-reinstall.sh <백업> --security` |
| 7 | 중지·자동 확장 | 백업 때 중지돼 있던 환경은 **서비스 중지**, 자동 확장은 **자동 확장 설정**으로 다시 적용 |

업체 개발자에게 알릴 것:
- 새 주소: `https://cicd.kpaas.example.co.kr`, `https://scm.kpaas.example.co.kr`
- git remote 변경: `git remote set-url origin https://scm-manager.kpaas.example.co.kr/scm/git/<저장소>`
- (방식 A) 새 `ca.crt` 설치, 임시 비밀번호로 첫 로그인 후 SCM git 비밀번호 다시 설정

---

## 7. 검증 체크리스트

- [ ] 사용자 PC에서 `https://portal.<도메인>`, `https://cicd.<도메인>` 접속 — 인증서 경고 없음, 주소에 IP 없음
- [ ] 모든 노드: `getent hosts harbor.<도메인>` → Ingress IP
- [ ] 클러스터: `nslookup portal.<도메인>` (3-3 명령) → Ingress IP
- [ ] Keycloak 로그인(포털, 콘솔, Jenkins, Argo CD) 후 로그아웃 정상
- [ ] 콘솔 **시스템 점검** 성공
- [ ] 업체 앱 dev 빌드 → Harbor push → dev 접속(`https://<앱>-<업체>-dev.<도메인>`)
- [ ] 앱 DB 데이터 확인 (복원한 게시글 등)
- [ ] 저장소·코드 어디에도 옛 주소가 남지 않음:

```bash
grep -rn "nip.io" ~/Saeoll-PaaS/*/script/*vars*.sh
```

---

## 8. 문제 해결

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| `deploy-cp-portal.sh`: `DNS (this node) ... not found` | DNS 레코드 없음 또는 관리 노드가 내부 DNS를 안 씀 | 1-2, 3-2 |
| `dns-check-<숫자>...` 만 실패 | 와일드카드가 아니라 개별 레코드만 등록 | `*.도메인` 레코드로 등록 |
| `DNS (cluster/CoreDNS)` 실패 | Pod가 내부 DNS를 모름 | 3-3 CoreDNS 전달 설정 |
| Pod `ImagePullBackOff` (`harbor.<도메인>`) | 노드가 도메인을 못 찾거나 CA를 신뢰하지 않음 | 해당 노드에서 `getent hosts`, `cp-portal-deployment/script/recover-node-ca.sh` |
| 브라우저 인증서 경고 | PC가 사설 CA를 신뢰하지 않음 | `ca.crt` 설치(방식 A) 또는 기관 인증서(방식 B) |
| Keycloak `Invalid redirect uri` | 옛 도메인으로 접속 또는 설치 중 도메인 변경 | 새 도메인 주소로 접속, 도메인을 바꿨다면 CP-Portal부터 다시 설치 |
| `restore --repos`: `already has branches - skipped` | 앱 추가에서 시작 소스가 먼저 들어감 | 시작 소스를 넣지 않음으로 앱 추가했는지 확인, 필요하면 `FORCE=1` |
| `restore --db`: `not connected yet` | DB 연결 전 | 콘솔 DB 연결 후 다시 실행 |
