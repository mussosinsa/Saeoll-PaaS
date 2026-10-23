# CI templates

Pushed to GitLab project `cicd/ci-templates` by `deploy-cicd-portal.sh templates`.
Application projects include one language template:

```yaml
include:
  - project: cicd/ci-templates
    ref: main            # or a release tag such as v1.0.0
    file: /templates/php.yml   # java-gradle | java-maven | php | node | vue
```

| Branch / tag | Jobs | Deployment |
| --- | --- | --- |
| any branch, merge request | build, test | - |
| `develop` | build, test, image, deploy | gitops `apps/<app>/overlays/dev` → Argo CD auto sync → `<group>-dev` |
| tag `vX.Y.Z` (Maintainers only) | build, test, image, deploy | gitops `apps/<app>/overlays/prod` → Argo CD **manual** sync → `<group>-prod` |

Images: `harbor.<domain>/<group>/<project>:dev-<sha>-<pipeline>` or `:vX.Y.Z`.
Dockerfiles receive `BASE_REGISTRY` (instance variable `CICD_BASE_REGISTRY`).
