# 폐쇄망 RKE2 K-PaaS에 CI/CD 포털 설치하기 (백업 이미지 → Harbor 등록 포함, 초보자용)

인터넷이 되는 **지금 K-PaaS**에서 CI/CD 포털에 필요한 이미지와 차트를 백업하고, 인터넷이 없는 **폐쇄망 RKE2 K-PaaS**로
가져가서 Harbor에 등록한 뒤 CI/CD 포털(Jenkins·Argo CD·GitLab·콘솔·보안 검사)을 설치하는 전 과정이다.
명령은 순서대로 복사해서 실행하면 된다.

```
 [인터넷 O: 지금 K-PaaS 관리 노드]                       [폐쇄망: RKE2 + K-PaaS 관리 노드]
  1. harbor-export.sh  ──► harbor-export-<날짜>.tar ──┐
     (Harbor 이미지 + 언어·DB 이미지                   │  2. 반입 (USB·망연계) + sha256 확인
      + Argo CD·GitLab 등 + 차트)                      ├─► 3. 저장소 풀기
  1. git bundle        ──► Saeoll-PaaS.bundle ────────┘   4. setup-cicd-env.sh (설정 마법사)
                                                              ├ Harbor 등록 (load-to-harbor.sh)
                                                              ├ 인증서·비밀번호 확인
                                                              └ RKE2 노드 스크립트 생성
                                                           5. 모든 노드에서 rke2-node-ca.sh (CA + Harbor 미러)
                                                           6. 마법사 다시 실행 → 점검 → 배포
                                                           7. 확인
```

**전제**: 폐쇄망 쪽에 RKE2 클러스터와 K-PaaS **CP-Portal(Harbor·Keycloak·MariaDB)** 이 설치되어 있고,
SCM 업체를 쓰면 **cp-source-control**도 설치되어 있다. (설치 순서: [설치 순서 (초보자용)](install-order-beginner.md))

| 용어 | 뜻 |
|---|---|
| 관리 노드 | `kubectl`이 되는 서버 (예: `k8s-cp01`). 명령은 모두 여기서 `root`로 실행 |
| 백업 파일 | `harbor-export-<날짜>.tar` — 이미지 + 차트 묶음 |
| 마법사 | `setup-cicd-env.sh` — 값을 묻고, 확인하고, 설치까지 진행하는 스크립트 |
| Harbor 미러 | Harbor의 `mirror` 프로젝트. Argo CD·GitLab처럼 docker.io·quay.io에서 받던 이미지를 여기서 받게 한다 |

---

## 1. 인터넷 쪽 — 백업 만들기 (지금 K-PaaS 관리 노드, 약 30~60분)

### 1-1. 저장소 최신으로

```bash
cd ~/Saeoll-PaaS && git pull origin claude/stoic-edison-jc393z
```

### 1-2. 도구 확인

```bash
sudo dnf install -y skopeo podman git
```

```bash
kubectl get nodes && helm version --short
```

### 1-3. (권장) 콘솔·보안 검사 이미지 새로 만들기

최신 스크립트와 최신 취약점 DB가 들어가도록 한다. 콘솔을 쓰지 않으면 건너뛴다.

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script && ./deploy-cicd-portal.sh security-image console-image
```

### 1-4. 이미지·차트 백업

```bash
cd ~/Saeoll-PaaS/offline && ./harbor-export.sh ~/harbor-export-$(date +%Y%m%d) 2>&1 | tee harbor-export.log
```

백업되는 것:

| 새 Harbor 위치 | 내용 |
|---|---|
| `cicd-portal/` | 콘솔·보안 검사 이미지 (비공개) |
| `cicd-mirror/` | Jenkins + 지금 설치된 플러그인, Jenkins 초기화 이미지, kaniko (공개) |
| `base-images/` | PHP·Java·Node.js·Vue 빌드/실행 이미지, MariaDB·PostgreSQL, alpine (공개) |
| `mirror/<레지스트리>/...` | Argo CD·Redis·Dex·Jenkins agent·GitLab·GitLab Runner·Gitleaks·Trivy·Presidio — **지금 클러스터의 `cicd-*` 네임스페이스에서 실제로 쓰는 이미지** (공개) |
| `charts/` | Jenkins·Argo CD·GitLab Runner 차트 (지금 설치된 버전) + `versions.env` |

끝에 `[WARN] not exported` 목록이 없어야 한다. 있으면 그 항목만 원인을 고치고 다시 실행한다(이미 받은 것도 다시 받는다).

> 업체 앱 이미지도 옮기려면 업체 프로젝트를 추가한다: `HARBOR_PROJECTS="cicd-portal cicd-mirror base-images soft" ./harbor-export.sh ...`
> 다른 옵션은 [Harbor 이미지 옮기기 2-3](harbor-image-migration.md#2-3-옵션).

### 1-5. 스크립트 저장소 묶기

```bash
cd ~/Saeoll-PaaS && git bundle create ~/Saeoll-PaaS.bundle --all
```

### 1-6. (폐쇄망에 skopeo가 없으면) 설치 파일 받기

폐쇄망의 dnf 저장소에 skopeo가 있으면 건너뛴다.

```bash
mkdir -p ~/skopeo-rpms && cd ~/skopeo-rpms && dnf download --resolve skopeo
```

### 1-7. 반입할 파일

```bash
ls -lh ~/harbor-export-*.tar* ~/Saeoll-PaaS.bundle
```

| 파일 | 크기(예) |
|---|---|
| `harbor-export-<날짜>.tar` + `.tar.sha256` | 5~10 GB |
| `Saeoll-PaaS.bundle` | 수십 MB |
| (필요 시) `skopeo-rpms/` | 수십 MB |

승인된 매체(USB, 망연계 시스템)로 복사한다. **`ca.key`(CA 개인 키)는 필요 없다. 복사하지 않는다.**

---

## 2. 폐쇄망 — 반입과 확인 (관리 노드)

1. 반입한 파일을 `/opt`에 둔다.
2. 손상 여부를 확인한다. `OK`가 나와야 한다.

```bash
cd /opt && sha256sum -c harbor-export-*.tar.sha256
```

3. (필요 시) skopeo 설치

```bash
sudo dnf install -y skopeo || sudo dnf install -y /opt/skopeo-rpms/*.rpm
```

> 압축은 풀지 않아도 된다. Harbor 등록 단계가 `.tar`를 확인하고 옆에 풀어서 쓴다(여유 공간: tar 크기만큼 더 필요).

---

## 3. 폐쇄망 — 저장소 풀기 (관리 노드)

```bash
cd ~ && git clone -b claude/stoic-edison-jc393z /opt/Saeoll-PaaS.bundle Saeoll-PaaS
```

이미 `~/Saeoll-PaaS`가 있으면(CP-Portal을 이 저장소로 설치한 경우) 덮어쓰지 말고 갱신만 한다:

```bash
cd ~/Saeoll-PaaS && git pull /opt/Saeoll-PaaS.bundle claude/stoic-edison-jc393z
```

CP-Portal을 **다른 폴더나 다른 서버**에서 설치했다면 그때의 `cp-portal-vars.sh`와 `certs/ca.crt`를
`~/Saeoll-PaaS/cp-portal-deployment/script/`, `~/Saeoll-PaaS/cp-portal-deployment/certs/`에 복사해 두면 편하다
(없어도 마법사가 클러스터에서 찾거나 물어본다).

---

## 4. 설정 마법사 — Harbor 등록과 값 설정 (관리 노드, 약 20~40분)

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script && ./setup-cicd-env.sh
```

`[ ]` 안이 기본값이다. **Enter**를 누르면 그 값을 쓴다. 비밀번호는 화면에 보이지 않는다.

| 마법사 질문 | 폐쇄망에서 입력할 것 |
|---|---|
| 1/7 Kubernetes 접속 | (자동) RKE2 `kubectl`·`/etc/rancher/rke2/rke2.yaml` |
| 2/7 도메인 | Enter (CP-Portal 도메인이 자동으로 나옴) |
| 3/7 인증서 | 보통 자동. 못 찾으면 CP-Portal 설치 때의 `ca.crt` 경로 |
| 4/7 Keycloak·Harbor·MariaDB 비밀번호 | 설정 파일 값으로 로그인되면 묻지 않음. 실패하면 **현재** 비밀번호 |
| 5/7 소스 | `scm` (K-PaaS SCM + Jenkins) / `gitlab` / `scm gitlab` |
| 5/7 SCM 관리자 git 비밀번호 | `https://scm.<도메인>` → `scmadmin` → 내정보 관리에서 정한 **git 비밀번호** |
| 5/7 StorageClass / IngressClass | 목록에서 선택 (보통 Enter) |
| 5/7 Pod Security | `baseline` (Enter) / 업체: 비움 또는 `baseline` |
| **6/7 폐쇄망입니까?** | **`y`** |
| **6/7 이미지 백업 파일/폴더** | **`/opt/harbor-export-<날짜>.tar`** (최근 파일이 기본값으로 나옴) |
| **6/7 Harbor에 등록할까요?** | **Enter(Y)** → 이미지 등록 진행 (수 분~수십 분, `[n/전체]` 진행 표시) |
| 6/7 Helm 차트 폴더 | Enter (`/opt/harbor-export-<날짜>/charts`) |
| 6/7 `JENKINS_IMAGE` 등 (Harbor) | Enter (방금 등록한 Harbor 이미지가 자동으로 나옴) |
| 6/7 사내 Nexus 주소 | 있으면 `http://<nexus>:8081`, 없으면 Enter |
| 7/7 모든 노드에서 실행했습니까? | 처음에는 **`n`** → 마법사가 값을 저장하고 멈춘다 → 5장 |

### Harbor 등록에서 일어나는 일

- `.tar`의 sha256을 다시 확인하고, `/opt/harbor-export-<날짜>/`에 푼다.
- Harbor에 프로젝트를 만든다: `cicd-portal`(비공개), `cicd-mirror`·`base-images`·`mirror`(공개).
- 이미지를 올린다. digest로 받는 이미지(예: Argo CD의 Redis)는 **digest를 그대로** 올린다.
- 로그: `~/Saeoll-PaaS/cicd-portal-deployment/values/load-to-harbor.log`
- 다시 실행해도 된다(같은 이미지는 그대로). 등록을 건너뛰려면 "이미지 백업" 질문에 `-` 입력.

> 마법사 없이 직접 등록하려면: `cd ~/Saeoll-PaaS/offline && ./load-to-harbor.sh /opt/harbor-export-<날짜>.tar`
> (Harbor 계정은 `cp-portal-vars.sh`에서 읽는다. 끝에 `cicd-vars.sh`에 넣을 값이 출력된다.)

Harbor 화면(`https://harbor.<도메인>` → 프로젝트)에서 `cicd-portal`, `cicd-mirror`, `base-images`, `mirror`가 보이면 된다.

---

## 5. RKE2 노드 설정 — CA와 Harbor 미러 (모든 노드, 노드당 1~2분)

마법사가 `~/Saeoll-PaaS/cicd-portal-deployment/values/rke2-node-ca.sh`를 만들었다. 이 스크립트는:

- K-PaaS CA를 노드의 신뢰 저장소(`/etc/pki/ca-trust/source/anchors/`)에 넣는다.
- `/etc/rancher/rke2/registries.yaml`에 Harbor 인증서(`configs`)와 **미러**를 추가한다:
  `quay.io/argoproj/argocd` → `harbor.<도메인>/mirror/quay.io/argoproj/argocd` (rewrite).
  차트·매니페스트는 그대로 두고 노드가 Harbor에서 받게 하는 방식이다.
- 바뀐 것이 있으면 `rke2-server`(또는 `rke2-agent`)를 재시작한다. **실행 중인 Pod는 그대로 동작**한다.
- 기존 파일은 `registries.yaml.bak.<시각>`으로 백업한다. 여러 번 실행해도 같은 항목을 두 번 넣지 않는다.

**모든 노드(제어 노드 포함)** 에서 root로 한 번 실행한다. 관리 노드:

```bash
sudo bash ~/Saeoll-PaaS/cicd-portal-deployment/values/rke2-node-ca.sh
```

다른 노드 (노드 이름은 `kubectl get nodes`로 확인):

```bash
for n in k8s-cp02 k8s-cp03 k8s-worker01 k8s-worker02; do scp ~/Saeoll-PaaS/cicd-portal-deployment/values/rke2-node-ca.sh $n:/tmp/ && ssh $n sudo bash /tmp/rke2-node-ca.sh; done
```

> 제어 노드를 동시에 재시작하지 않도록 한 대씩 순서대로 실행된다(위 반복문). 각 노드가 `Ready`로 돌아오는지 확인한다:
> `kubectl get nodes`

**확인** (관리 노드에서, 미러에 올라간 quay.io 이미지 하나를 원래 이름으로 받아 보기):

```bash
img=$(awk -F'\t' '$1 ~ /^mirror\/quay.io\//{sub(/^mirror\//,"",$1); print $1; exit}' /opt/harbor-export-*/images/harbor-images.txt); echo "$img"
```

```bash
sudo /var/lib/rancher/rke2/bin/crictl --config /var/lib/rancher/rke2/agent/etc/crictl.yaml pull "$img"
```

`Image is up to date` 또는 이미지 ID(`sha256:...`)가 나오면 된다. 인터넷이 없는데 받아졌다면 Harbor 미러가 동작한 것이다.

> **`[WARN] ... already has a mirror for docker.io - kept`** 가 나오면: 이 클러스터는 이미 다른 미러(예: 부트스트랩 VM의
> 레지스트리)로 docker.io를 받고 있다. 그 설정은 그대로 두었으므로, docker.io 이미지(Jenkins agent, GitLab, Trivy 등)는
> **그 미러에도** 있어야 한다. Harbor에 올라간 것을 그 미러로 복사한다(부트스트랩 레지스트리 예):
>
> ```bash
> for img in $(awk -F'\t' '$1 ~ /^mirror\/docker.io\//{sub(/^mirror\//,"",$1); print $1}' /opt/harbor-export-*/images/harbor-images.txt); do skopeo copy --src-tls-verify=true --dest-tls-verify=false docker://harbor.<도메인>/mirror/$img docker://<부트스트랩>:5000/$img; done
> ```

---

## 6. 마법사 다시 실행 — 점검과 배포 (약 40~90분)

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script && ./setup-cicd-env.sh
```

앞에서 입력한 값이 모두 기본값으로 나오므로 **Enter**만 누른다. 달라지는 질문만 정리:

| 질문 | 입력 |
|---|---|
| 이미지 백업 파일/폴더 | Enter (이미 등록한 백업이면 다음 "등록할까요?"의 기본값이 `N` → Enter) |
| 모든 노드에서 실행했습니까? | **`y`** |
| SCM 비밀번호를 저장할까요? | `n` 권장 (다음에 다시 입력) |

이어서 자동으로 **사전 점검**(`./deploy-cicd-portal.sh preflight`)을 한다. `[FAIL]`이 없어야 다음으로 간다.
점검이 끝나면 단계마다 묻는다:

| 질문 | 답 | 하는 일 |
|---|---|---|
| Keycloak 설정 + 소스 + Argo CD 설치 | Y | Jenkins(또는 GitLab)·Argo CD 설치. 차트는 `charts/`, 이미지는 Harbor에서 |
| Jenkins API 토큰 등록 (scm) | Y | ① 운영자 ID 입력 → `cicd-admins` 그룹에 추가 ② `https://jenkins.<도메인>` 로그인 → 사용자 → Security → API Token → **Add new Token** ③ 토큰 붙여넣기 |
| CI/CD 콘솔 설치 | Y | 폐쇄망: 이미지 빌드 없이 Harbor의 `cicd-portal/cicd-console` 사용 |
| 보안 검사 설치 | 필요하면 Y | Harbor의 `cicd-portal/security-scanner` 사용 |

---

## 7. 확인

```bash
cd ~/Saeoll-PaaS/cicd-portal-deployment/script && ./check-cicd-portal.sh
```

브라우저(사용자 PC에 K-PaaS CA를 신뢰시킨 뒤):

| 주소 | 확인 |
|---|---|
| `https://cicd.<도메인>` | 콘솔 로그인 (K-PaaS 계정, `cicd-admins` 구성원은 관리자 메뉴) |
| `https://argocd.<도메인>` | Argo CD 로그인 |
| `https://jenkins.<도메인>` | Jenkins 로그인 (scm) |
| `https://gitlab.<도메인>` | GitLab 로그인 (gitlab) |

모든 Pod가 Harbor에서 이미지를 받았는지:

```bash
kubectl get pods -A | grep -E 'cicd-' | grep -vE 'Running|Completed'
```

아무것도 나오지 않으면 정상이다. 다음은 업체 등록 → [콘솔 운영 관리자 가이드](../cicd-portal-deployment/docs/console-admin-guide.md).

---

## 8. 문제 해결

| 증상 | 원인 | 조치 |
|---|---|---|
| `sha256 mismatch` | 반입 중 손상 | 다시 복사 |
| 백업 중 `Harbor API ...: HTTP 500` | 일부 Harbor 버전의 저장소 목록 API 오류 | 정상 진행: 자동으로 `skopeo list-tags`로 조회 (`repository list via the registry API`). 업체 앱 이미지는 `FALLBACK_REPOS="<프로젝트>/<저장소> ..."` |
| 등록 중 `Harbor login failed` | Harbor admin 비밀번호가 다름 | 마법사 4/7에서 현재 비밀번호 입력 (마법사가 확인한 값으로 등록) |
| 등록 중 `push failed` | Harbor 디스크 부족, 네트워크 | Harbor 화면 **시스템 관리 → 저장소 사용량**, 로그 `values/load-to-harbor.log` 확인 후 다시 실행 |
| `x509: certificate signed by unknown authority` (Pod `ErrImagePull`) | 그 노드에 CA 미설치 | 그 노드에서 `rke2-node-ca.sh` 실행 |
| `ErrImagePull` … `quay.io`/`docker.io` … `i/o timeout` | 노드에 미러가 없음 | 그 노드에서 `rke2-node-ca.sh` 실행. `docker.io`는 5장 WARN 참고 |
| `ErrImagePull` … `mirror/...: not found` | 백업에 그 이미지가 없음 (원본에 없던 버전) | 인터넷 쪽에서 `EXTRA_MIRROR_IMAGES="<이미지>" ./harbor-export.sh` → 반입 → 등록 |
| Jenkins가 플러그인을 받으려다 실패 | `JENKINS_IMAGE`가 플러그인 포함 이미지가 아님 | 마법사 6/7의 `JENKINS_IMAGE`가 `cicd-mirror/jenkins:*-plugins`인지 확인 |
| 차트 `not found` | `CICD_CHART_DIR` 경로 | 마법사 6/7 차트 폴더에 `.tgz`가 있는지 확인 |
| 앱 빌드에서 `docker.io/library/...` 받기 실패 | `CICD_DOCKERHUB`/`CICD_BASE_REGISTRY` 미설정 | 마법사 6/7에서 Harbor `base-images` 값 사용 |
| 앱 빌드에서 Maven/npm 의존성 실패 | 라이브러리는 이미지가 아님 | 사내 Nexus → [폐쇄망 설치 6장](install-offline.md#6-사내-저장소-nexus-3-앱-빌드-의존성) |
| 노드 재시작 후 `NotReady` 오래 지속 | `registries.yaml` 문법 | `/etc/rancher/rke2/registries.yaml.bak.*`로 되돌리고 `systemctl restart rke2-server`(또는 `rke2-agent`), `journalctl -u rke2-server -n 50` |

---

## 9. 한눈에 보기

```bash
# [인터넷 쪽 관리 노드]
cd ~/Saeoll-PaaS && git pull origin claude/stoic-edison-jc393z
cd ~/Saeoll-PaaS/offline && ./harbor-export.sh ~/harbor-export-$(date +%Y%m%d)
cd ~/Saeoll-PaaS && git bundle create ~/Saeoll-PaaS.bundle --all
# → harbor-export-<날짜>.tar, .tar.sha256, Saeoll-PaaS.bundle 을 폐쇄망 /opt 로 반입

# [폐쇄망 관리 노드]
cd /opt && sha256sum -c harbor-export-*.tar.sha256
cd ~ && git clone -b claude/stoic-edison-jc393z /opt/Saeoll-PaaS.bundle Saeoll-PaaS
cd ~/Saeoll-PaaS/cicd-portal-deployment/script && ./setup-cicd-env.sh     # 폐쇄망 y, 백업 tar 등록, 노드 질문 n
# 모든 노드: sudo bash rke2-node-ca.sh  (values/rke2-node-ca.sh 복사해서)
./setup-cicd-env.sh                                                         # 노드 질문 y → 점검 → 설치
./check-cicd-portal.sh
```

관련 문서: [CI/CD 포털 환경 정보와 환경 변수](cicd-portal-env-reference.md) ·
[Harbor 이미지 옮기기](harbor-image-migration.md) · [폐쇄망 전체 설치 (서버 초기화부터)](offline-install-beginner.md)
