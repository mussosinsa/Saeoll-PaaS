// {VENDOR}/{APP} image deploy - CI/CD portal (application type "image": the vendor pushes a ready image to Harbor)
// Job {APP}-deploy, managed by the portal (stored in the Jenkins job, not in a vendor repository):
//   TARGET=dev  : any pushed tag                    -> security gate -> gitops overlays/dev  -> Argo CD auto sync
//   TARGET=prod : vX.Y.Z already deployed to dev    -> security gate -> gitops overlays/prod -> Argo CD sync by cicd-admins
// The image is pinned by digest (newTag: <tag>@sha256:...), so prod runs exactly what was tested in dev.
// Parameters are set by the CI/CD console (이미지 배포 / prod 승격), which resolves the tag to its digest in Harbor.
def vendor = '{VENDOR}'
def app = '{APP}'
def imageRepo = '{IMAGE_REPO}'
def gitopsRepo = '{GITOPS_REPO_URL}'
def securityImage = '{SECURITY_IMAGE}'
def securityEnabled = securityImage && !securityImage.startsWith('{')

def securityContainer = !securityEnabled ? '' : """
    - name: security
      image: ${securityImage}
      command: ["sleep"]
      args: ["infinity"]
      resources:
        requests: {cpu: 250m, memory: 512Mi}
        limits: {memory: 2Gi}
      envFrom:
        - secretRef: {name: cicd-security-defectdojo, optional: true}
      volumeMounts:
        - {name: cicd-ca, mountPath: /etc/cicd-ca, readOnly: true}
        - {name: security-policy, mountPath: /etc/cicd-security/policy, readOnly: true}
        - {name: security-rules, mountPath: /etc/cicd-security/rules, readOnly: true}
  imagePullSecrets:
    - name: cicd-security-pull"""
def securityVolumes = !securityEnabled ? '' : """
    - name: security-policy
      configMap: {name: cicd-security-policy, optional: true}
    - name: security-rules
      configMap: {name: cicd-security-rules, optional: true}"""

podTemplate(yaml: """
apiVersion: v1
kind: Pod
spec:
  containers:${securityContainer ?: ' []'}
  volumes:
    - name: cicd-ca
      secret: {secretName: cicd-ca}${securityVolumes}
""") {
  node(POD_LABEL) {
    def tag = (params.IMAGE_TAG ?: '').trim()
    def digest = (params.IMAGE_DIGEST ?: '').trim()
    def target = (params.TARGET ?: 'dev').trim()
    def ref = "${imageRepo}@${digest}"

    stage('Check') {
      if (!(tag ==~ /[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}/)) {
        error "IMAGE_TAG '${tag}' is not a valid image tag"
      }
      if (!(digest ==~ /sha256:[0-9a-f]{64}/)) {
        error "IMAGE_DIGEST must be sha256:<64 hex> (deploy from the CI/CD console, which resolves it in Harbor)"
      }
      if (!(target in ['dev', 'prod'])) {
        error "TARGET must be dev or prod (got '${target}')"
      }
      if (target == 'prod' && !(tag ==~ /v\d+\.\d+\.\d+/)) {
        error "prod accepts release tags vX.Y.Z only (got '${tag}')"
      }
      currentBuild.displayName = "#${env.BUILD_NUMBER} ${target} ${tag}"
      currentBuild.description = digest.substring(0, 19)
    }

    // gitops clone (full history: the prod promotion checks what dev has run)
    stage('Gitops') {
      container('jnlp') {
        withCredentials([usernamePassword(credentialsId: "${vendor}-scm",
                                          usernameVariable: 'SCM_USER', passwordVariable: 'SCM_PASSWORD')]) {
          withEnv(["GITOPS_REPO=${gitopsRepo}", "DEV_OVERLAY=apps/${app}/overlays/dev/kustomization.yaml",
                   "DIGEST=${digest}", "TARGET=${target}"]) {
            sh '''
              set -e
              cred='!f() { echo "username=$SCM_USER"; echo "password=$SCM_PASSWORD"; }; f'
              rm -rf gitops-repo
              git -c credential.helper="$cred" clone -q --branch main "$GITOPS_REPO" gitops-repo
              cd gitops-repo
              [ -f "$DEV_OVERLAY" ] || { echo "$DEV_OVERLAY not found - run 앱 추가 (add-app.sh, type image)"; exit 1; }
              if [ "$TARGET" = prod ]; then
                # promotion: the same digest must have been deployed to dev (now or before)
                if ! grep -q "@$DIGEST" "$DEV_OVERLAY" && ! git log --format= -p -- "$DEV_OVERLAY" | grep -q "^+.*@$DIGEST"; then
                  echo "Image $DIGEST was never deployed to dev. Deploy it to dev and test it first (CI/CD console 이미지 배포)."
                  exit 1
                fi
                echo "Promotion check passed: $DIGEST was deployed to dev"
              fi
            '''
          }
        }
      }
    }

    // Gate: exit 0 pass, 10 limits exceeded in report mode (build UNSTABLE), else fail = no deployment
    stage('Security Gate') {
      if (!securityEnabled) {
        echo 'Security scan is not set up (./deploy-cicd-portal.sh security-image security, then 앱 추가 again)'
        return
      }
      def gate = 0
      try {
        container('security') {
          withCredentials([usernamePassword(credentialsId: "${vendor}-harbor",
                                            usernameVariable: 'TRIVY_USERNAME', passwordVariable: 'TRIVY_PASSWORD')]) {
            withEnv(["CICD_APP=${vendor}/${app}", "CICD_ENV=${target}", "CICD_APP_TYPE=image", "CICD_REF=${tag}",
                     "CICD_COMMIT=${digest}", "CICD_BUILD_URL=${env.BUILD_URL}", "CICD_CA_FILE=/etc/cicd-ca/ca.crt",
                     "CICD_IMAGE=${ref}"]) {
              sh 'cicd-scan image --image "$CICD_IMAGE" --out security'
              gate = sh(script: 'cicd-scan gate --out security', returnStatus: true)
              sh 'cicd-scan upload --out security'
            }
          }
        }
      } finally {
        archiveArtifacts artifacts: 'security/**', allowEmptyArchive: true
      }
      if (gate == 10) {
        unstable('Security limits exceeded (report mode) - CI/CD console > 품질 관리 > 보안 이슈')
      } else if (gate != 0) {
        error('Security gate failed: deployment blocked - CI/CD console > 품질 관리 > 보안 이슈')
      }
    }

    stage('Deploy') {
      container('jnlp') {
        withCredentials([usernamePassword(credentialsId: "${vendor}-scm",
                                          usernameVariable: 'SCM_USER', passwordVariable: 'SCM_PASSWORD')]) {
          withEnv(["OVERLAY=apps/${app}/overlays/${target}/kustomization.yaml", "IMAGE_TAG=${tag}@${digest}",
                   "COMMIT_MSG=${app} ${target} -> ${tag} (${env.JOB_NAME} #${env.BUILD_NUMBER})"]) {
            sh '''
              set -e
              cred='!f() { echo "username=$SCM_USER"; echo "password=$SCM_PASSWORD"; }; f'
              cd gitops-repo
              git config user.name "Jenkins"
              git config user.email "jenkins@cicd-portal"
              for attempt in 1 2 3; do
                sed -i "s|^\\(    newTag:\\).*|\\1 $IMAGE_TAG|" "$OVERLAY"
                git add "$OVERLAY"
                if git diff --cached --quiet; then echo "Already at $IMAGE_TAG"; exit 0; fi
                git commit -q -m "$COMMIT_MSG"
                if git -c credential.helper="$cred" push -q origin HEAD:main; then break; fi
                [ "$attempt" = 3 ] && exit 1
                git -c credential.helper="$cred" fetch -q origin main
                git reset -q --hard origin/main
              done
              echo "gitops $OVERLAY -> $IMAGE_TAG"
            '''
          }
        }
      }
      if (target == 'prod') {
        echo "Production: ask cicd-admins to sync '${vendor}-${app}-prod' (CI/CD console prod Sync)."
      } else {
        echo "Argo CD syncs '${vendor}-${app}-dev' automatically."
      }
    }
  }
}
