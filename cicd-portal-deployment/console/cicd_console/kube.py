"""kubectl helpers (in the cluster kubectl uses the pod's service account)."""
import base64
import json
import os
import subprocess
import time


class KubeError(Exception):
    pass


def kubectl(*args, stdin=None, timeout=30):
    try:
        out = subprocess.run(["kubectl", *args], input=stdin, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        raise KubeError("kubectl is not installed") from None
    except subprocess.TimeoutExpired:
        raise KubeError(f"kubectl {' '.join(args[:3])} timed out") from None
    if out.returncode != 0:
        raise KubeError(out.stderr.strip() or f"kubectl {' '.join(args)} failed")
    return out.stdout


def get_json(*args):
    """kubectl get ... -o json; None if the object does not exist."""
    try:
        return json.loads(kubectl("get", *args, "-o", "json"))
    except KubeError as e:
        if "NotFound" in str(e) or "not found" in str(e):
            return None
        raise


_cache = {}


def secret_value(namespace, name, key, ttl=60):
    """One key of a Secret (cached for ttl seconds); empty string if missing."""
    ck = (namespace, name, key)
    hit = _cache.get(ck)
    if hit and hit[0] > time.time():
        return hit[1]
    value = ""
    try:
        data = (get_json("-n", namespace, "secret", name) or {}).get("data") or {}
        if key in data:
            value = base64.b64decode(data[key]).decode()
    except KubeError:
        value = ""
    _cache[ck] = (time.time() + ttl, value)
    return value


def cicd_secret(key):
    """Generated credential of the CI/CD portal (same lookup as lib.sh get_secret)."""
    env = os.environ
    if key.startswith(("gitlab-", "root-password", "automation-token")):
        first = env["GITLAB_NAMESPACE"]
    elif key.startswith(("jenkins-", "kc-jenkins-")):
        first = env["JENKINS_NAMESPACE"]
    else:
        first = env["ARGOCD_NAMESPACE"]
    for ns in (first, env["JENKINS_NAMESPACE"], env["GITLAB_NAMESPACE"]):
        value = secret_value(ns, env["SECRET_NAME"], key)
        if value:
            return value
    return ""
