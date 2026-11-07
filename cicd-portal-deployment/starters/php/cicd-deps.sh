# cicd-deps.sh - dependency repositories of the build (CI/CD portal). Sourced by the Jenkinsfile, the GitLab CI
# templates and the Dockerfile:  . ./cicd-deps.sh
# NEXUS_URL set (closed network, CI/CD portal setting CICD_NEXUS_URL, e.g. http://bootstrap.example:8081):
# Maven, Gradle, npm and Composer use the company Nexus repositories instead of the internet. Not set: nothing
# changes. Writes its files to CICD_DEPS_DIR (default ./.cicd-deps) and exports the tools' variables.
case "${NEXUS_URL:-}" in '$'*|'{'*) NEXUS_URL="" ;; esac   # unset CI variable / unrendered placeholder
if [ -n "${NEXUS_URL:-}" ]; then
  _n="${NEXUS_URL%/}"
  _d="${CICD_DEPS_DIR:-$PWD/.cicd-deps}"
  mkdir -p "$_d/gradle/init.d" "$_d/composer"
  # Maven (also ./mvnw): every repository through maven-public; the http blocker of Maven 3.8+ is replaced
  cat > "$_d/settings.xml" <<CICDEOF
<settings>
  <mirrors>
    <mirror><id>cicd-nexus</id><mirrorOf>*</mirrorOf><url>$_n/repository/maven-public/</url></mirror>
    <mirror><id>maven-default-http-blocker</id><mirrorOf>cicd-none</mirrorOf><url>http://0.0.0.0/</url></mirror>
  </mirrors>
</settings>
CICDEOF
  export MAVEN_ARGS="-s $_d/settings.xml ${MAVEN_ARGS:-}"
  export MVNW_REPOURL="$_n/repository/maven-public"
  # Gradle (also ./gradlew builds): every Maven repository (mavenCentral, gradlePluginPortal, ...) -> maven-public
  cat > "$_d/gradle/init.d/cicd-nexus.gradle" <<CICDEOF
def cicdNexus = '$_n/repository/maven-public/'
def cicdUseNexus = { repos ->
  repos.all { r ->
    if (r instanceof MavenArtifactRepository && r.url.toString() != cicdNexus) {
      r.url = cicdNexus
      r.allowInsecureProtocol = cicdNexus.startsWith('http:')
    }
  }
}
settingsEvaluated { s ->
  cicdUseNexus(s.pluginManagement.repositories)
  s.pluginManagement.repositories.maven { url cicdNexus; allowInsecureProtocol = cicdNexus.startsWith('http:') }
}
allprojects {
  cicdUseNexus(buildscript.repositories)
  cicdUseNexus(repositories)
}
CICDEOF
  export GRADLE_USER_HOME="$_d/gradle"
  # ./gradlew: its distribution from files-offline/gradle/ (collect-app-deps.sh), only in this build's copy
  if [ -f gradle/wrapper/gradle-wrapper.properties ]; then
    sed -i "s#^distributionUrl=.*/\([^/]*\)\$#distributionUrl=$_n/repository/files-offline/gradle/\1#" gradle/wrapper/gradle-wrapper.properties
  fi
  # npm (package-lock.json registry.npmjs.org URLs are rewritten to this registry by npm)
  export npm_config_registry="$_n/repository/npm-public/"
  # Composer: the Nexus composer repository only (packagist.org off)
  printf '{"config":{"secure-http":false},"repositories":[{"type":"composer","url":"%s/repository/composer-offline/"},{"packagist.org":false}]}\n' \
    "$_n" > "$_d/composer/config.json"
  export COMPOSER_HOME="$_d/composer"
  echo "[cicd-deps] dependencies from $_n (Maven, Gradle, npm, Composer)"
  unset _n _d
fi
