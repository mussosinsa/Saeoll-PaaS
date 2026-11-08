#!/bin/bash
# Collect everything a closed-network installation needs into an offline bundle (docs/install-offline.md).
# Run on the admin node of the CURRENT, internet-connected installation (Rocky Linux 9.7, kubectl to the
# running cluster) - before the servers are wiped. The running cluster tells which images and chart versions
# are needed, so the closed network gets exactly what works here.
#
# Usage: ./collect-bundle.sh [bundle-dir] [step ...]        (default: ../offline-bundle-<date>, all steps)
#   images     images of the running cluster (pods, deployments, statefulsets, daemonsets, cronjobs) + build/tool
#              images (Jenkins agent, GitLab runner helper, starters' CI images, kaniko, MariaDB, Presidio, ...)
#              + EXTRA_IMAGES -> images/oci (OCI layout, shared layers) and images/images.txt
#              IMAGES_FROM=<images.txt of an earlier bundle>: the list instead of the cluster (update bundles)
#   cicd       images built for the portal from the current Harbor (cicd-portal/cicd-console, security-scanner),
#              a Jenkins controller image with the installed plugins built in, the base images of the starters'
#              Dockerfiles -> images/harbor-images.txt (pushed into Harbor by load-to-harbor.sh)
#   charts     K-PaaS charts (cp-portal, cp-pipeline) + Jenkins, Argo CD, GitLab Runner charts at the versions
#              running now -> charts/, charts/versions.env
#   files      kubectl, helm, step, istioctl, the helm-push plugin, the source control package -> files/
#   rpms       Rocky Linux repositories (RPM_REPOS, dnf reposync, ~15 GB) -> rpms/<repo>/
#   kubespray  Kubernetes binaries for kubespray (standalone/contrib/offline) -> files/kubespray/
#   appdeps    build dependencies (Maven/Gradle/npm/Composer) of the starters, the samples and APP_SOURCES
#              (directories or git URLs of the vendors' applications) for the company Nexus -> appdeps/
#   repo       this repository (git bundle) -> Saeoll-PaaS.bundle
# Needs: kubectl, helm, podman, skopeo, git, dnf-plugins-core (reposync), python3; internet access.
# Before: rebuild the scanner image (fresh Trivy DB) and the console image with the current scripts:
#   cicd-portal-deployment/script: ./deploy-cicd-portal.sh security-image console-image
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=offline-vars.sh
source "$SCRIPT_DIR/offline-vars.sh"

OUT=${1:-"$REPO/../offline-bundle-$(date +%Y%m%d)"}
[[ $# -gt 0 ]] && shift
STEPS=${*:-"images cicd charts files rpms kubespray appdeps repo"}
mkdir -p "$OUT"/{images,charts,files,rpms}
OUT=$(cd "$OUT" && pwd)
info() { echo "[INFO] $*"; }
ok() { echo "[OK]   $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }
has_step() { [[ " $STEPS " == *" $1 "* ]]; }
FAILED=()

# Settings of the current installation (read in a subshell: the vars files define many names)
portal_vars() { (set +u; source "$REPO/cp-portal-deployment/script/cp-portal-vars.sh" >/dev/null 2>&1; for v in "$@"; do echo "${!v}"; done); }
cicd_vars() { (set +u; source "$REPO/cicd-portal-deployment/script/cicd-vars.sh" >/dev/null 2>&1; for v in "$@"; do echo "${!v}"; done); }
mapfile -t P < <(portal_vars HOST_DOMAIN REPOSITORY_USERNAME)
HOST_DOMAIN=${P[0]}
HARBOR_HOST="harbor.$HOST_DOMAIN"
CA_FILE="$REPO/cp-portal-deployment/certs/ca.crt"

# Fully qualified image name: nginx:1 -> docker.io/library/nginx:1, foo/bar -> docker.io/foo/bar
qualify() {
  local ref=$1 first=${1%%/*}
  if [[ "$ref" != */* ]]; then echo "docker.io/library/$ref"
  elif [[ "$first" != *.* && "$first" != *:* && "$first" != localhost ]]; then echo "docker.io/$ref"
  else echo "$ref"; fi
}
oci_name() { echo "$1" | tr '/:@' '___'; }

# 1. images -------------------------------------------------------------------------------------------------------
if has_step images; then
  require() { command -v "$1" >/dev/null || die "$1 is not installed"; }
  require skopeo
  [[ -n "${IMAGES_FROM:-}" ]] || { require kubectl; require helm; }
  list="$OUT/images/images.all"
  : > "$list"
  # IMAGES_FROM=<images.txt of an earlier bundle>: update bundle without the online cluster (internet PC)
  if [[ -n "${IMAGES_FROM:-}" ]]; then
    cut -f1 "$IMAGES_FROM" >> "$list"
  else
  for kind in pods deployments statefulsets daemonsets cronjobs jobs; do
    kubectl get "$kind" -A -o json 2>/dev/null | python3 -c '
import json, sys
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in ("containers", "initContainers", "ephemeralContainers") and isinstance(v, list):
                for c in v:
                    if isinstance(c, dict) and c.get("image"):
                        print(c["image"])
            else:
                walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(json.load(sys.stdin))' >> "$list" || true
  done
  # build-time images: Jenkins agent, GitLab runner helper
  agent=$(helm get values jenkins -n "$(cicd_vars JENKINS_NAMESPACE)" -a -o json 2>/dev/null | python3 -c '
import json, sys
a = (json.load(sys.stdin).get("agent") or {}).get("image") or {}
if isinstance(a, dict) and a.get("repository"):
    print(((a.get("registry") + "/") if a.get("registry") else "") + a["repository"] + ":" + str(a.get("tag", "")))' 2>/dev/null || true)
  [[ -n "$agent" ]] && echo "$agent" >> "$list"
  runner=$(helm list -A -o json 2>/dev/null | python3 -c '
import json, sys
print(next((r["app_version"] for r in json.load(sys.stdin) if r["chart"].startswith("gitlab-runner-")), ""))' || true)
  [[ -n "$runner" ]] && echo "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:x86_64-v${runner#v}" >> "$list"
  fi
  # CI images of the starters and the portal settings
  dockerhub=$(cicd_vars CICD_DOCKERHUB)
  grep -rhoE '(\{CICD_DOCKERHUB\}|\$CICD_DOCKERHUB)/[A-Za-z0-9._:/-]+' "$REPO/cicd-portal-deployment/starters" \
    "$REPO/cicd-portal-deployment/ci-templates" "$REPO/cicd-portal-deployment/values_orig" 2>/dev/null | \
    sed -e "s|{CICD_DOCKERHUB}|${dockerhub:-docker.io/library}|" -e "s|\$CICD_DOCKERHUB|${dockerhub:-docker.io/library}|" >> "$list" || true
  cicd_vars KANIKO_IMAGE JENKINS_TOOL_IMAGE MARIADB_IMAGE PRESIDIO_IMAGE GITLAB_IMAGE SECURITY_GITLEAKS_IMAGE \
    SECURITY_TRIVY_IMAGE SECURITY_BASE_IMAGE CONSOLE_BASE_IMAGE >> "$list"
  printf '%s\n' $EXTRA_IMAGES >> "$list"
  # qualify, drop the images built here (Harbor of this installation: cicd step / application backup)
  : > "$OUT/images/images.txt"
  sort -u "$list" | while read -r img; do
    [[ -n "$img" ]] || continue
    q=$(qualify "$img")
    [[ "$q" == "$HARBOR_HOST/"* || "$q" == localhost/* ]] && continue
    printf '%s\t%s\n' "$q" "$(oci_name "$q")" >> "$OUT/images/images.txt"
  done
  info "$(wc -l < "$OUT/images/images.txt") images -> images/oci"
  # every registry must be mirrored by the bootstrap registry (node-setup.sh), else the nodes cannot pull it
  unmirrored=$(cut -f1 "$OUT/images/images.txt" | cut -d/ -f1 | sort -u | while read -r r; do
    [[ " $MIRRORED_REGISTRIES " == *" $r "* ]] || echo "$r"; done)
  [[ -z "$unmirrored" ]] || warn "registries not in MIRRORED_REGISTRIES (offline-vars.sh) - add them: $(echo $unmirrored)"
  while IFS=$'\t' read -r img name; do
    # digest-pinned references (e.g. ingress-nginx) keep their multi-arch index so the digest still matches
    mode=(); [[ "$img" == *@sha256:* ]] && mode=(--all --preserve-digests)
    if skopeo copy --quiet --retry-times 3 "${mode[@]}" "docker://$img" "oci:$OUT/images/oci:$name" 2>/dev/null; then
      ok "$img"
    else
      FAILED+=("image $img"); warn "$img: copy failed"
    fi
  done < "$OUT/images/images.txt"
  rm -f "$list"
fi

# 2. portal images (current Harbor), Jenkins with plugins, base images ---------------------------------------------
if has_step cicd; then
  : > "$OUT/images/harbor-images.txt"
  auth="$OUT/.auth.json"
  umask_old=$(umask); umask 077
  harbor_pw=$(portal_vars REPOSITORY_PASSWORD)
  python3 -c 'import base64,json,sys;json.dump({"auths":{sys.argv[1]:{"auth":base64.b64encode((sys.argv[2]+":"+sys.argv[3]).encode()).decode()}}},open(sys.argv[4],"w"))' \
    "$HARBOR_HOST" "${P[1]}" "$harbor_pw" "$auth"
  unset harbor_pw
  umask "$umask_old"
  certdir=$(mktemp -d); [[ -f "$CA_FILE" ]] && cp "$CA_FILE" "$certdir/ca.crt"
  project=$(cicd_vars CONSOLE_HARBOR_PROJECT); project=${project:-cicd-portal}
  for repo in cicd-console security-scanner; do
    tag=$(cicd_vars "$([[ $repo == cicd-console ]] && echo CONSOLE_IMAGE_TAG || echo SECURITY_IMAGE_TAG)")
    src="$HARBOR_HOST/$project/$repo:${tag:-1.0.0}"
    name="harbor_${project}_${repo}_${tag:-1.0.0}"
    if skopeo copy --quiet --authfile "$auth" --src-cert-dir "$certdir" "docker://$src" "oci:$OUT/images/oci:$name"; then
      printf '%s\t%s\t%s\n' "$project/$repo:${tag:-1.0.0}" "$name" private >> "$OUT/images/harbor-images.txt"
      ok "$src"
    else
      FAILED+=("image $src"); warn "$src: copy failed (built? ./deploy-cicd-portal.sh console-image security-image)"
    fi
  done
  # Jenkins controller image + the plugins installed in the running Jenkins (exact versions, no download later)
  jns=$(cicd_vars JENKINS_NAMESPACE)
  if kubectl -n "$jns" get pod jenkins-0 >/dev/null 2>&1; then
    jimg=$(kubectl -n "$jns" get pod jenkins-0 -o jsonpath='{.spec.containers[?(@.name=="jenkins")].image}')
    ctx=$(mktemp -d)
    mkdir -p "$ctx/plugins"
    kubectl -n "$jns" exec jenkins-0 -c jenkins -- sh -c 'cd /var/jenkins_home/plugins && tar cf - $(ls *.jpi *.hpi 2>/dev/null)' | \
      tar xf - -C "$ctx/plugins"
    count=$(ls "$ctx/plugins" | wc -l)
    printf 'FROM %s\nCOPY plugins/ /usr/share/jenkins/ref/plugins/\n' "$(qualify "$jimg")" > "$ctx/Containerfile"
    jtag="${jimg##*:}-plugins"
    if podman build -q -t "localhost/cicd-jenkins:$jtag" -f "$ctx/Containerfile" "$ctx" >/dev/null && \
       skopeo copy --quiet "containers-storage:localhost/cicd-jenkins:$jtag" "oci:$OUT/images/oci:harbor_cicd-mirror_jenkins_$jtag"; then
      printf '%s\t%s\t%s\n' "cicd-mirror/jenkins:$jtag" "harbor_cicd-mirror_jenkins_$jtag" public >> "$OUT/images/harbor-images.txt"
      ok "Jenkins $jimg + $count plugins -> cicd-mirror/jenkins:$jtag"
    else
      FAILED+=("Jenkins image"); warn "Jenkins image build failed"
    fi
    rm -rf "$ctx"
  else
    info "Jenkins is not running here: no Jenkins image (SCM vendors need it)"
  fi
  # base images of the application Dockerfiles -> Harbor base-images (public, like cp-pipeline mirror-base-images.sh)
  base=$(cicd_vars CICD_BASE_REGISTRY); base=${base:-docker.io/library}
  { grep -rhoE '^FROM \$\{BASE_REGISTRY\}/[^ ]+' "$REPO/cicd-portal-deployment/starters" | sed 's|^FROM ${BASE_REGISTRY}/||'
    printf '%s\n' $EXTRA_BASE_IMAGES; } | sort -u | while read -r b; do
    [[ -n "$b" ]] || continue
    name="base_$(oci_name "$b")"
    if skopeo copy --quiet "docker://docker.io/library/$b" "oci:$OUT/images/oci:$name" 2>/dev/null; then
      printf '%s\t%s\t%s\n' "base-images/$b" "$name" public >> "$OUT/images/harbor-images.txt"
      ok "base image $b"
    else
      warn "base image $b: copy failed"
    fi
  done
  rm -rf "$auth" "$certdir"
fi

# 3. charts ---------------------------------------------------------------------------------------------------------
if has_step charts; then
  for d in cp-portal-deployment/charts cp-pipeline-deployment/charts; do
    [[ -d "$REPO/$d" ]] && cp -n "$REPO/$d"/*.tgz "$OUT/charts/" 2>/dev/null || true
  done
  # K-PaaS charts listed in the vars files that are not there yet
  for vars in cp-portal-deployment/script/cp-portal-vars.sh cp-pipeline-deployment/script/cp-pipeline-vars.sh; do
    [[ -f "$REPO/$vars" ]] || continue
    (set +u; source "$REPO/$vars" >/dev/null 2>&1
     for c in "${!CHART_VERSION[@]}"; do
       [[ -f "$OUT/charts/$c-${CHART_VERSION[$c]}.tgz" ]] && continue
       helm pull -d "$OUT/charts" "$K_PAAS_HELM_OCI_REPO/$c" --version "${CHART_VERSION[$c]}" >/dev/null && echo "[OK]   chart $c ${CHART_VERSION[$c]}" || \
         echo "[WARN] chart $c ${CHART_VERSION[$c]}: pull failed" >&2
     done)
  done
  # Jenkins / Argo CD / GitLab Runner at the versions running now (pinned for the closed network)
  : > "$OUT/charts/versions.env"
  while read -r chart version; do
    case "$chart" in
      jenkins) url=https://charts.jenkins.io var=JENKINS_CHART_VERSION ;;
      argo-cd) url=https://argoproj.github.io/argo-helm var=ARGOCD_CHART_VERSION ;;
      gitlab-runner) url=https://charts.gitlab.io var=GITLAB_RUNNER_CHART_VERSION ;;
      *) continue ;;
    esac
    if helm pull -d "$OUT/charts" --repo "$url" "$chart" --version "$version" >/dev/null; then
      echo "$var=\"$version\"" >> "$OUT/charts/versions.env"; ok "chart $chart $version"
    else
      FAILED+=("chart $chart $version"); warn "chart $chart $version: pull failed"
    fi
  done < <(helm list -A -o json | python3 -c '
import json, re, sys
for r in json.load(sys.stdin):
    m = re.match(r"^(.*)-(v?\d+\.\d+\.\d+.*)$", r["chart"])
    if m: print(m.group(1), m.group(2))' | sort -u)
fi

# 4. files ------------------------------------------------------------------------------------------------------------
if has_step files; then
  (source "$REPO/cp-portal-deployment/istio_mc/tool-versions.sh"
   cd "$OUT/files"
   get() { [[ -f "$2" ]] || curl -fsSL -o "$2" "$1"; echo "[OK]   $2"; }
   get "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" kubectl
   get "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" "helm-v${HELM_VERSION}-linux-amd64.tar.gz"
   get "https://dl.smallstep.com/gh-release/cli/docs-cli-install/v${STEP_VERSION}/step-cli_${STEP_VERSION}_amd64.rpm" "step-cli_${STEP_VERSION}_amd64.rpm"
   get "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz" "istio-${ISTIO_VERSION}-linux-amd64.tar.gz")
  plugins=$(helm env HELM_PLUGINS 2>/dev/null || true)
  if [[ -x "$plugins/helm-push/bin/helm-cm-push" ]]; then
    tar czf "$OUT/files/helm-push-plugin.tar.gz" -C "$plugins" helm-push && ok "helm-push plugin"
  else
    warn "helm-push plugin not installed here (helm plugin install https://github.com/chartmuseum/helm-push.git) - not bundled"
  fi
  sc=$(ls -t "$REPO"/cp-source-control-deployment/cp-source-control-deployment-*.tar.gz 2>/dev/null | head -1 || true)
  if [[ -z "$sc" ]]; then
    (cd "$OUT/files" && wget -q --content-disposition "https://nextcloud.k-paas.org/index.php/s/dkfdTd6zttpi3T2/download") || warn "source control package: download failed"
  else
    cp "$sc" "$OUT/files/"
  fi
  ls "$OUT"/files/cp-source-control-deployment-*.tar.gz >/dev/null 2>&1 && ok "source control package" || FAILED+=("source control package")
fi

# 5. rpms -------------------------------------------------------------------------------------------------------------
if has_step rpms; then
  for r in $RPM_REPOS $RPM_EXTRA_REPOS; do
    info "dnf reposync $r (large)"
    if dnf reposync -q --repoid="$r" --download-metadata --newest-only -p "$OUT/rpms"; then
      ok "rpms/$r"
    else
      FAILED+=("rpm repository $r"); warn "reposync $r failed"
    fi
  done
fi

# 6. kubespray --------------------------------------------------------------------------------------------------------
if has_step kubespray; then
  if [[ -x "$REPO/standalone/contrib/offline/generate_list.sh" ]] && command -v ansible-playbook >/dev/null; then
    (cd "$REPO/standalone/contrib/offline" && ./generate_list.sh >/dev/null && touch offline-files.tar.gz && \
       NO_HTTP_SERVER=1 ./manage-offline-files.sh >/dev/null) && \
      mkdir -p "$OUT/files/kubespray" && cp -r "$REPO/standalone/contrib/offline/offline-files/." "$OUT/files/kubespray/" && \
      cp "$REPO/standalone/contrib/offline/temp/images.list" "$OUT/images/kubespray-images.list" && ok "kubespray files" || \
      { FAILED+=("kubespray files"); warn "kubespray offline files failed"; }
  else
    info "kubespray: standalone/contrib/offline or ansible not available - skipped (other installers: see docs/install-offline.md 3-4)"
  fi
fi

# 7. application dependencies for the company Nexus -------------------------------------------------------------------
if has_step appdeps; then
  sources=()
  for d in "$REPO"/cicd-portal-deployment/starters/{java-gradle,java-maven,node,php,vue} "$REPO"/cicd-portal-deployment/samples/*/; do
    [[ -d "$d" ]] && sources+=("$d")
  done
  for s in ${APP_SOURCES:-}; do sources+=("$s"); done
  CICD_DOCKERHUB=$(cicd_vars CICD_DOCKERHUB) "$SCRIPT_DIR/collect-app-deps.sh" "$OUT/appdeps" "${sources[@]}" || \
    FAILED+=("application dependencies (see above)")
fi

# 8. this repository --------------------------------------------------------------------------------------------------
if has_step repo; then
  git -C "$REPO" bundle create "$OUT/Saeoll-PaaS.bundle" --all >/dev/null 2>&1 && ok "repository -> Saeoll-PaaS.bundle" || FAILED+=("repository")
fi

# manifest ------------------------------------------------------------------------------------------------------------
cp "$SCRIPT_DIR/offline-vars.sh" "$OUT/"
# the offline scripts themselves: the bootstrap VM runs them from the bundle (no git needed there)
mkdir -p "$OUT/scripts" && cp "$SCRIPT_DIR"/*.sh "$OUT/scripts/" && chmod 755 "$OUT"/scripts/*.sh
(cd "$OUT" && find . -type f ! -name SHA256SUMS ! -path './images/oci/blobs/*' -print0 | xargs -0 sha256sum > SHA256SUMS)
cat > "$OUT/README.txt" <<EOF
Offline bundle for the K-PaaS + CI/CD portal closed-network installation
Collected $(date '+%Y-%m-%d %H:%M') from $HOST_DOMAIN ($(git -C "$REPO" rev-parse --short HEAD 2>/dev/null))
Install: docs/install-offline.md (bootstrap-server.sh on the bootstrap VM first)
Check after copying: sha256sum -c SHA256SUMS
EOF
du -sh "$OUT" | awk '{print "[INFO] Bundle size: " $1}'
if ((${#FAILED[@]})); then
  printf '[WARN] Missing: %s\n' "${FAILED[@]}"
  exit 3
fi
echo "Bundle ready: $OUT"
