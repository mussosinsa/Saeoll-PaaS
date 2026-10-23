#!/bin/bash
# Register a vendor PHP service in the cp-pipeline Jenkins through its REST API:
#   folder <vendor>, folder credentials (Harbor robot, kubeconfig dev/prod, SCM)
#   and Pipeline jobs <app>-dev (Poll SCM, develop) / <app>-prod (release tag).
#
# Usage: ./register-php-jenkins-job.sh <vendor> <app> [scm-repository]
#   scm-repository : default <vendor>-<app>
# Run ./onboard-php-vendor.sh <vendor> first (reads ../vendors/<vendor>/).
#
# Env:
#   SCM_PASSWORD       git password of the Jenkins SCM account (required; set in
#                      scm.<domain> > 내정보 관리, not the Keycloak password)
#   SCM_USER           default jenkins-<vendor>
#   JENKINS_USER       Jenkins login (omit if Jenkins allows anonymous admin)
#   JENKINS_PASSWORD   password or API token of JENKINS_USER
#   JENKINS_URL        default: kubectl port-forward to cp-pipeline-jenkins-service
#   SCM_REPO_URL       default: in-cluster SCM-Manager service URL (http)
#   ENVS               default "dev prod"
#   DRY_RUN=1          print the generated XML without calling Jenkins
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
source cp-pipeline-vars.sh
PORTAL_VARS=${PORTAL_VARS:-"$SCRIPT_DIR/../../cp-portal-deployment/script/cp-portal-vars.sh"}
eval "$(sed -n '/^load_portal_vars()/,/^}/p' deploy-cp-pipeline.sh)"

VENDOR=${1:-}
APP=${2:-}
REPO=${3:-"$VENDOR-$APP"}
NAME_RE='^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$'
if [[ ! "$VENDOR" =~ $NAME_RE || ! "$APP" =~ $NAME_RE ]]; then
  echo "Usage: $0 <vendor> <app> [scm-repository]  (lowercase letters, digits, '-')" >&2
  exit 2
fi
ENVS=${ENVS:-"dev prod"}
SCM_USER=${SCM_USER:-"jenkins-$VENDOR"}
SCM_REPO_URL=${SCM_REPO_URL:-"http://cp-source-control-manager-service.cp-source-control.svc.cluster.local:8080/scm/git/$REPO"}
VENDOR_DIR="$SCRIPT_DIR/../vendors/$VENDOR"
DRY_RUN=${DRY_RUN:-0}

[[ -n "${SCM_PASSWORD:-}" ]] || { echo "[ERROR] Set SCM_PASSWORD (git password of $SCM_USER)." >&2; exit 2; }
[[ -r "$VENDOR_DIR/harbor-robot.env" ]] || {
  echo "[ERROR] $VENDOR_DIR/harbor-robot.env not found. Run ./onboard-php-vendor.sh $VENDOR first." >&2; exit 1; }
for env in $ENVS; do
  [[ -r "$VENDOR_DIR/kubeconfig-$env" ]] || {
    echo "[ERROR] $VENDOR_DIR/kubeconfig-$env not found. Run ./onboard-php-vendor.sh $VENDOR first." >&2; exit 1; }
done
# shellcheck disable=SC1091
source "$VENDOR_DIR/harbor-robot.env"
if [[ "$DRY_RUN" == 1 ]]; then
  load_portal_vars 2>/dev/null || HOST_DOMAIN=${HOST_DOMAIN/\{host domain\}/example.nip.io}
else
  load_portal_vars
fi

xml() { python3 -c 'import sys; from xml.sax.saxutils import escape; print(escape(sys.argv[1]), end="")' "$1"; }

### XML ########################################################################
folder_xml() {
  cat <<EOF
<?xml version='1.1' encoding='UTF-8'?>
<com.cloudbees.hudson.plugins.folder.Folder>
  <description>$(xml "PHP services of $VENDOR (registered by register-php-jenkins-job.sh)")</description>
</com.cloudbees.hudson.plugins.folder.Folder>
EOF
}

userpass_xml() { # id username password description
  cat <<EOF
<com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
  <scope>GLOBAL</scope>
  <id>$(xml "$1")</id>
  <description>$(xml "$4")</description>
  <username>$(xml "$2")</username>
  <password>$(xml "$3")</password>
</com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
EOF
}

secretfile_xml() { # id file description
  cat <<EOF
<org.jenkinsci.plugins.plaincredentials.impl.FileCredentialsImpl>
  <scope>GLOBAL</scope>
  <id>$(xml "$1")</id>
  <description>$(xml "$3")</description>
  <fileName>kubeconfig</fileName>
  <secretBytes>$(base64 -w0 "$2")</secretBytes>
</org.jenkinsci.plugins.plaincredentials.impl.FileCredentialsImpl>
EOF
}

string_param() { # name default description
  cat <<EOF
          <hudson.model.StringParameterDefinition>
            <name>$1</name>
            <description>$(xml "$3")</description>
            <defaultValue>$(xml "$2")</defaultValue>
            <trim>true</trim>
          </hudson.model.StringParameterDefinition>
EOF
}

job_xml() { # env
  local env=$1 branch lightweight trigger="" first second
  if [[ "$env" == prod ]]; then
    branch='refs/tags/${RELEASE_TAG}'; lightweight=false; first=prod; second=dev
  else
    branch='*/develop'; lightweight=true; first=dev; second=prod
    trigger="
    <org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
      <triggers>
        <hudson.triggers.SCMTrigger>
          <spec>H/5 * * * *</spec>
          <ignorePostCommitHooks>false</ignorePostCommitHooks>
        </hudson.triggers.SCMTrigger>
      </triggers>
    </org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>"
  fi
  # Job-level parameters match the Jenkinsfile so the first run (and the
  # ${RELEASE_TAG} branch of the prod job) resolve before the Jenkinsfile runs.
  cat <<EOF
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition>
  <description>$(xml "$VENDOR/$APP $env deployment ($REPO)")</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty/>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
          <hudson.model.ChoiceParameterDefinition>
            <name>DEPLOY_ENV</name>
            <description>dev: develop branch, prod: release tag</description>
            <choices class="java.util.Arrays\$ArrayList">
              <a class="string-array"><string>$first</string><string>$second</string></a>
            </choices>
          </hudson.model.ChoiceParameterDefinition>
$(string_param VENDOR "$VENDOR" "Vendor id (namespace prefix, Harbor project)")
$(string_param APP_NAME "$APP" "Application name (lowercase, -)")
$(string_param BASE_DOMAIN "$HOST_DOMAIN" "Cluster HOST_DOMAIN")
$(string_param RELEASE_TAG "" "prod only: release tag, e.g. v1.2.0")
$(string_param APPROVERS "admin" "prod only: Jenkins users/groups allowed to approve")
$(string_param BASE_PROJECT "base-images" "Harbor project with mirrored base images (empty: Docker Hub)")
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>$trigger
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition">
    <scm class="hudson.plugins.git.GitSCM">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>$(xml "$SCM_REPO_URL")</url>
          <credentialsId>$VENDOR-scm</credentialsId>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>$branch</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class="empty-list"/>
      <extensions/>
    </scm>
    <scriptPath>Jenkinsfile</scriptPath>
    <lightweight>$lightweight</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
EOF
}

### DRY RUN ####################################################################
if [[ "$DRY_RUN" == 1 ]]; then
  echo "===== folder $VENDOR"; folder_xml
  echo "===== credential $VENDOR-harbor-robot"
  userpass_xml "$VENDOR-harbor-robot" "$HARBOR_ROBOT_USER" '********' "Harbor robot account"
  for env in $ENVS; do
    echo "===== credential $VENDOR-kubeconfig-$env (secret file, $VENDOR_DIR/kubeconfig-$env)"
  done
  echo "===== credential $VENDOR-scm"; userpass_xml "$VENDOR-scm" "$SCM_USER" '********' "SCM account"
  for env in $ENVS; do echo "===== job $VENDOR/$APP-$env"; job_xml "$env"; done
  exit 0
fi

### JENKINS ####################################################################
for cmd in curl python3 ${JENKINS_URL:+:} kubectl; do
  [[ "$cmd" == : ]] && break
  command -v "$cmd" >/dev/null || { echo "[ERROR] $cmd is not installed." >&2; exit 1; }
done
WORK=$(mktemp -d)
PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

if [[ -z "${JENKINS_URL:-}" ]]; then
  PORT=${JENKINS_LOCAL_PORT:-18080}
  kubectl -n "$NAMESPACE" port-forward svc/cp-pipeline-jenkins-service "$PORT:8080" >"$WORK/pf.log" 2>&1 &
  PF_PID=$!
  JENKINS_URL="http://127.0.0.1:$PORT"
  for _ in $(seq 1 20); do
    curl -s -o /dev/null "$JENKINS_URL/login" && break
    sleep 1
  done
fi
JENKINS_URL=${JENKINS_URL%/}

# curl config on stdin keeps the Jenkins password out of ps
jcurl() {
  {
    [[ -n "${JENKINS_USER:-}" ]] && \
      printf 'user = "%s"\n' "$(printf '%s:%s' "$JENKINS_USER" "${JENKINS_PASSWORD:-}" | sed -e 's/[\\"]/\\&/g')"
    [[ -n "${CRUMB_HEADER:-}" ]] && printf 'header = "%s"\n' "$CRUMB_HEADER"
    true
  } | curl -s -b "$WORK/cookies" -c "$WORK/cookies" -K - "$@"
}
status() { jcurl -o /dev/null -w '%{http_code}' "$@"; }
post_xml() { # url file -> http code
  jcurl -o "$WORK/resp" -w '%{http_code}' -X POST -H 'Content-Type: application/xml' --data-binary @"$2" "$1"
}

code=$(status "$JENKINS_URL/api/json")
case "$code" in
  200) echo "[OK] Jenkins reachable: $JENKINS_URL" ;;
  401|403) echo "[ERROR] Jenkins denied access (HTTP $code). Set JENKINS_USER and JENKINS_PASSWORD (or API token)." >&2; exit 1 ;;
  *) echo "[ERROR] Cannot reach Jenkins at $JENKINS_URL (HTTP $code)." >&2; cat "$WORK/pf.log" 2>/dev/null >&2; exit 1 ;;
esac

crumb=$(jcurl "$JENKINS_URL/crumbIssuer/api/json" 2>/dev/null | \
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["crumbRequestField"]+": "+d["crumb"])' 2>/dev/null || true)
CRUMB_HEADER=$crumb

plugins=$(jcurl "$JENKINS_URL/pluginManager/api/json?tree=plugins%5BshortName%5D" | \
  python3 -c 'import json,sys; print(" ".join(p["shortName"] for p in json.load(sys.stdin)["plugins"]))' 2>/dev/null || true)
missing=""
for p in cloudbees-folder workflow-job workflow-cps git credentials plain-credentials pipeline-input-step; do
  [[ " $plugins " == *" $p "* ]] || missing+=" $p"
done
if [[ -n "$missing" ]]; then
  echo "[ERROR] Required Jenkins plugins missing:$missing (Manage Jenkins > Plugins)" >&2
  exit 1
fi

# Folder (created only if missing: re-posting its config would drop folder credentials)
FOLDER_URL="$JENKINS_URL/job/$VENDOR"
if [[ "$(status "$FOLDER_URL/api/json")" == 200 ]]; then
  echo "[INFO] Folder exists: $VENDOR"
else
  folder_xml >"$WORK/folder.xml"
  code=$(post_xml "$JENKINS_URL/createItem?name=$VENDOR" "$WORK/folder.xml")
  [[ "$code" == 200 ]] || { echo "[ERROR] Cannot create folder $VENDOR (HTTP $code)" >&2; cat "$WORK/resp" >&2; exit 1; }
  echo "[OK] Folder created: $VENDOR"
fi

# Folder-scoped credentials (create or update)
STORE="$FOLDER_URL/credentials/store/folder/domain/_"
put_credential() { # id xml-file
  local id=$1 file=$2 code
  if [[ "$(status "$STORE/credential/$id/api/json")" == 200 ]]; then
    code=$(post_xml "$STORE/credential/$id/config.xml" "$file"); action=updated
  else
    code=$(post_xml "$STORE/createCredentials" "$file"); action=created
  fi
  [[ "$code" == 200 ]] || { echo "[ERROR] Credential $id (HTTP $code)" >&2; cat "$WORK/resp" >&2; exit 1; }
  echo "[OK] Credential $action: $id"
}
userpass_xml "$VENDOR-harbor-robot" "$HARBOR_ROBOT_USER" "$HARBOR_ROBOT_SECRET" "Harbor robot account ($VENDOR)" >"$WORK/c.xml"
put_credential "$VENDOR-harbor-robot" "$WORK/c.xml"
for env in $ENVS; do
  secretfile_xml "$VENDOR-kubeconfig-$env" "$VENDOR_DIR/kubeconfig-$env" "deployer kubeconfig for $VENDOR-$env" >"$WORK/c.xml"
  put_credential "$VENDOR-kubeconfig-$env" "$WORK/c.xml"
done
userpass_xml "$VENDOR-scm" "$SCM_USER" "$SCM_PASSWORD" "SCM read-only account ($SCM_USER)" >"$WORK/c.xml"
put_credential "$VENDOR-scm" "$WORK/c.xml"
rm -f "$WORK/c.xml"

# Pipeline jobs (create or update)
for env in $ENVS; do
  job="$APP-$env"
  job_xml "$env" >"$WORK/job.xml"
  if [[ "$(status "$FOLDER_URL/job/$job/api/json")" == 200 ]]; then
    code=$(post_xml "$FOLDER_URL/job/$job/config.xml" "$WORK/job.xml"); action=updated
  else
    code=$(post_xml "$FOLDER_URL/createItem?name=$job" "$WORK/job.xml"); action=created
  fi
  [[ "$code" == 200 ]] || { echo "[ERROR] Job $VENDOR/$job (HTTP $code)" >&2; cat "$WORK/resp" >&2; exit 1; }
  echo "[OK] Job $action: $VENDOR/$job"
done

echo
echo "SCM repository : $SCM_REPO_URL"
echo "Dev job        : $VENDOR/$APP-dev  (Poll SCM H/5, branch develop) -> $VENDOR-dev"
[[ " $ENVS " == *" prod "* ]] && \
  echo "Prod job       : $VENDOR/$APP-prod (manual, RELEASE_TAG + approval) -> $VENDOR-prod"
echo "Next           : run '$VENDOR/$APP-dev' once (Build Now), then pushes to develop deploy automatically."
echo "                 Restrict who can run '$VENDOR/$APP-prod' in Jenkins security settings."
