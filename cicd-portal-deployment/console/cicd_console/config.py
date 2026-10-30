"""Console settings, derived exactly like the scripts do (lib.sh load_portal_vars).

The console runs next to the scripts (image: /opt/cicd/script). At start it sources lib.sh, runs
load_portal_vars and copies the resulting variables into os.environ, so the console, cicd_api.py and
the scripts it starts all use the same domain, URLs and credentials.
"""
import os
import subprocess
import sys

SCRIPT_DIR = os.path.abspath(os.environ.get(
    "CICD_SCRIPT_DIR", os.path.join(os.path.dirname(__file__), "..", "..", "script")))

# Variables exported by lib.sh (cicd-vars.sh + load_portal_vars) that the console uses
VARS = [
    "HOST_DOMAIN", "CICD_SOURCES", "ARGOCD_NAMESPACE", "JENKINS_NAMESPACE", "GITLAB_NAMESPACE",
    "SECRET_NAME", "KEYCLOAK_ADMIN_GROUP", "KEYCLOAK_URL", "KEYCLOAK_ISSUER", "KEYCLOAK_CP_REALM", "KC_REALM",
    "KEYCLOAK_ADMIN_USERNAME", "KEYCLOAK_ADMIN_PASSWORD", "CA_FILE", "GITLAB_URL", "GITLAB_HOST",
    "JENKINS_URL", "JENKINS_HOST", "SCM_URL", "SCM_ADMIN_USER", "HARBOR_URL", "HARBOR_HOST",
    "REPOSITORY_USERNAME", "REPOSITORY_PASSWORD", "ARGOCD_HOST", "SCM_INTERNAL_GIT_URL", "GITLAB_INTERNAL_URL",
    "CONSOLE_HOST",
]


def load():
    """Fill os.environ from lib.sh. CICD_CONSOLE_CONFIG=env skips it (tests: values come from the env)."""
    if os.environ.get("CICD_CONSOLE_CONFIG") != "env":
        script = ('source ./lib.sh >/dev/null && load_portal_vars >/dev/null && '
                  'for v in "$@"; do printf "%s=%s\\0" "$v" "${!v}"; done')
        out = subprocess.run(["bash", "-c", script, "load", *VARS], cwd=SCRIPT_DIR, capture_output=True,
                             text=True, timeout=60)
        if out.returncode != 0:
            sys.exit(f"[ERROR] lib.sh load_portal_vars failed: {out.stderr.strip()}")
        for item in out.stdout.split("\0"):
            if "=" in item:
                key, value = item.split("=", 1)
                os.environ[key] = value
    env = os.environ
    env.setdefault("ARGOCD_NAMESPACE", "cicd-argocd")
    env.setdefault("JENKINS_NAMESPACE", "cicd-jenkins")
    env.setdefault("GITLAB_NAMESPACE", "cicd-gitlab")
    env.setdefault("SECRET_NAME", "cicd-portal-secrets")
    env.setdefault("KEYCLOAK_ADMIN_GROUP", "cicd-admins")
    env.setdefault("CICD_SOURCES", "scm gitlab")
    env.setdefault("CONSOLE_HOST", "cicd." + env.get("HOST_DOMAIN", "localhost"))
    return env


def sources():
    return os.environ.get("CICD_SOURCES", "").split()
