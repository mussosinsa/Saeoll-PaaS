"""ingress_to_istio.py: K-PaaS Ingresses (ingress-nginx) -> Istio VirtualServices.

  cd gateway && python3 -m unittest discover -s tests -v
"""
import os
import re
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import ingress_to_istio as c  # noqa: E402

GW = "istio-system/cp-gateway"
D = "k.kr"


def ing(ns, name, host, paths, ann=None, cls="nginx"):
    return {"metadata": {"namespace": ns, "name": name,
                         "annotations": {f"nginx.ingress.kubernetes.io/{k}": v for k, v in (ann or {}).items()}},
            "spec": {"ingressClassName": cls, "tls": [{"hosts": [host], "secretName": f"{D}-tls"}],
                     "rules": [{"host": host, "http": {"paths": [
                         {"path": p, "pathType": t, "backend": {"service": {"name": s, "port": port}}}
                         for p, t, s, port in paths]}}]}}


def svc(ns, name, *ports):
    return {"metadata": {"namespace": ns, "name": name}, "spec": {"ports": [{"name": n, "port": p} for n, p in ports]}}


# CP-Portal chart values (cp-portal-deployment/values_orig/cp-portal.yaml)
PORTAL = ing("cp-portal", "cp-portal-ingress", f"portal.{D}", [
    ("/(.*)", "ImplementationSpecific", "cp-portal-ui-service", {"number": 8090}),
    ("/cpapi/(.*)", "ImplementationSpecific", "cp-portal-api-service", {"number": 3333}),
    ("/cpcatalog/(.*)", "ImplementationSpecific", "cp-portal-catalog-api-service", {"number": 8093}),
    ("/(cpmigui/.*)", "ImplementationSpecific", "cp-portal-migration-ui-service", {"number": 8097}),
], {"rewrite-target": "/$1"})
HARBOR = ing("harbor", "harbor-ingress", f"harbor.{D}", [
    ("/api/", "Prefix", "harbor-core", {"number": 80}),
    ("/v2/", "Prefix", "harbor-core", {"number": 80}),
    ("/", "Prefix", "harbor-portal", {"name": "http"}),
], {"proxy-body-size": "0", "ssl-redirect": "true"})
CONSOLE = ing("cicd-console", "cicd-console", f"cicd.{D}", [("/", "Prefix", "cicd-console", {"name": "http"})],
              {"proxy-body-size": "2100m", "proxy-read-timeout": "1800", "proxy-send-timeout": "1800",
               "proxy-request-buffering": "off"})
SERVICES = {"items": [svc("harbor", "harbor-portal", ("http", 80)), svc("cicd-console", "cicd-console", ("http", 80))]}


def run(*ingresses, vs=None, **kw):
    return c.convert({"items": list(ingresses)}, SERVICES, {"items": vs or []}, GW, **kw)


def vs_of(res, host):
    return next(o for o in res["objects"] if o["kind"] == "VirtualService" and o["spec"]["hosts"] == [host])


def route_for(vs, path):
    """The route Envoy would pick for a path (first match in order) -> (destination host, rewritten path)."""
    for r in vs["spec"]["http"]:
        for m in r["match"]:
            u = m["uri"]
            hit = (u.get("exact") == path) or ("prefix" in u and path.startswith(u["prefix"])) or \
                  ("regex" in u and re.fullmatch(u["regex"], path))
            if not hit:
                continue
            rw = r.get("rewrite") or {}
            out = path
            if "uri" in rw:
                out = rw["uri"] + path[len(u["prefix"]):]
            elif "uriRegexRewrite" in rw:
                out = re.sub(rw["uriRegexRewrite"]["match"], rw["uriRegexRewrite"]["rewrite"].replace("\\", "\\"), path, count=1)
            return r["route"][0]["destination"]["host"].split(".")[0], out
    return None


class PortalTest(unittest.TestCase):
    def test_regex_rewrites_like_nginx(self):
        vs = vs_of(run(PORTAL), f"portal.{D}")
        self.assertEqual(vs["spec"]["gateways"], [GW])
        self.assertEqual(route_for(vs, "/cpapi/users/1"), ("cp-portal-api-service", "/users/1"))
        self.assertEqual(route_for(vs, "/cpcatalog/x"), ("cp-portal-catalog-api-service", "/x"))
        self.assertEqual(route_for(vs, "/cpmigui/app.js"), ("cp-portal-migration-ui-service", "/cpmigui/app.js"))
        self.assertEqual(route_for(vs, "/dashboard"), ("cp-portal-ui-service", "/dashboard"))
        self.assertEqual(vs["spec"]["http"][-1]["match"], [{"uri": {"prefix": "/"}}])     # catch-all last
        self.assertFalse(any("regex" in m["uri"] for r in vs["spec"]["http"] for m in r["match"]))   # all simple

    def test_harbor_prefix_paths_and_named_port(self):
        res = run(HARBOR)
        vs = vs_of(res, f"harbor.{D}")
        self.assertEqual(route_for(vs, "/v2/library/nginx/manifests/1"), ("harbor-core", "/v2/library/nginx/manifests/1"))
        self.assertEqual(route_for(vs, "/v2"), ("harbor-core", "/v2"))                    # Prefix: element-wise
        self.assertEqual(route_for(vs, "/v2x"), ("harbor-portal", "/v2x"))
        self.assertEqual(vs["spec"]["http"][-1]["route"][0]["destination"]["port"], {"number": 80})   # name http -> 80
        self.assertEqual([r for r in res["report"] if "WARN" in r], [])                 # body size, ssl-redirect: fine

    def test_console_timeout(self):
        vs = vs_of(run(CONSOLE), f"cicd.{D}")
        self.assertEqual(vs["spec"]["http"][0]["timeout"], "1800s")


class FeaturesTest(unittest.TestCase):
    def test_regex_fallback_and_app_root(self):
        i = ing("a", "api", f"api.{D}", [("/api/v[0-9]+/(.*)", "ImplementationSpecific", "api", {"number": 8080})],
                {"rewrite-target": "/$1", "app-root": "/ui"})
        vs = vs_of(run(i), f"api.{D}")
        self.assertEqual(vs["spec"]["http"][0], {"match": [{"uri": {"exact": "/"}}], "redirect": {"uri": "/ui"}})
        r = vs["spec"]["http"][1]
        self.assertEqual(r["match"], [{"uri": {"regex": "/api/v[0-9]+/(.*).*"}}])
        self.assertEqual(r["rewrite"], {"uriRegexRewrite": {"match": "^/api/v[0-9]+/(.*)", "rewrite": "/\\1"}})

    def test_destination_rules_and_unsupported(self):
        i = ing("a", "s", f"s.{D}", [("/", "Prefix", "s", {"number": 8443})],
                {"backend-protocol": "HTTPS", "affinity": "cookie", "session-cookie-name": "route",
                 "whitelist-source-range": "10.0.0.0/8", "configuration-snippet": "x"})
        res = run(i)
        dr = next(o for o in res["objects"] if o["kind"] == "DestinationRule")
        self.assertEqual(dr["spec"]["host"], "s.a.svc.cluster.local")
        self.assertEqual(dr["spec"]["trafficPolicy"]["tls"], {"mode": "SIMPLE", "insecureSkipVerify": True})
        self.assertEqual(dr["spec"]["trafficPolicy"]["loadBalancer"]["consistentHash"]["httpCookie"]["name"], "route")
        warns = "\n".join(res["report"])
        self.assertIn("whitelist-source-range", warns)
        self.assertIn("configuration-snippet", warns)

    def test_existing_virtualservice_kept_and_filters(self):
        mine = {"metadata": {"namespace": "x", "name": "old", "labels": {c.MANAGED: c.MANAGER}}, "spec": {"hosts": [f"cicd.{D}"]}}
        other = {"metadata": {"namespace": "cicd-console", "name": "cicd-console"}, "spec": {"hosts": [f"cicd.{D}"]}}
        self.assertEqual(run(CONSOLE, vs=[mine])["hosts"], [f"cicd.{D}"])          # own VS: regenerated
        res = run(CONSOLE, vs=[other])
        self.assertEqual(res["hosts"], [])                                           # someone else's: kept
        self.assertTrue(any("exists" in r for r in res["report"]))
        self.assertEqual(run(PORTAL, CONSOLE, namespaces=["harbor"])["hosts"], [])
        self.assertEqual(run(PORTAL, ing("x", "y", f"y.{D}", [("/", "Prefix", "y", {"number": 1})], cls="traefik"),
                             classes=["nginx"])["hosts"], [f"portal.{D}"])

    def test_same_host_two_ingresses(self):
        a = ing("a", "one", f"h.{D}", [("/", "Prefix", "web", {"number": 80})])
        b = ing("a", "two", f"h.{D}", [("/api", "Prefix", "api", {"number": 80})])
        res = run(a, b)
        vs = vs_of(res, f"h.{D}")
        self.assertEqual(route_for(vs, "/api/x")[0], "api")
        self.assertEqual(route_for(vs, "/x")[0], "web")
        self.assertEqual(vs["metadata"]["annotations"]["ingress-to-istio/sources"], "a/one,a/two")


if __name__ == "__main__":
    unittest.main()
