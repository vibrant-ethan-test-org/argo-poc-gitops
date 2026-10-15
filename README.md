# argo-poc-gitops

Deployment config for the Argo CD + Argo Rollouts proof of concept. Argo CD reads only this repo.
Each service's code and CI live in its own repo; all of them deploy through this one.

| Service | App repo | Test | Prod |
|---|---|---|---|
| `argo-poc` (web page) | [argo-poc-app](https://github.com/vibrant-ethan-test-org/argo-poc-app) | http://localhost:8081 | http://localhost:8091 |
| `argo-poc-api` (JSON API) | [argo-poc-api](https://github.com/vibrant-ethan-test-org/argo-poc-api) | http://localhost:8181/api/info | http://localhost:8191/api/info |

Preview (green) URLs are the same ports + 1 (8082, 8092, 8182, 8192).

```
push to an app repo's main
  → its ci.yaml calls release.yaml here: build + push images to GHCR,
    commit tags to apps/<service>/overlays/test
  → Argo CD syncs <service>-test → Argo Rollouts: green up, e2e on preview, switch traffic
  → Argo CD Notifications → repository_dispatch → on-deployed.yaml
      → GitHub Deployment "test" on the app commit (in the service's own repo)
      → PR "<service> prod: vX" updating apps/<service>/overlays/prod (with app changelog)
  → merge PR → Argo CD syncs <service>-prod → blue-green + e2e again → Deployment "prod"
```

Services release independently. If e2e fails, Rollouts aborts, the old version keeps serving,
the app goes Degraded, no notification fires and no prod PR is opened.

## Layout

| Path | What |
|---|---|
| `bootstrap/` | `kind-config.yaml`, `install.sh` (cluster, Argo CD, Argo Rollouts, UI extension, root app) |
| `apps/<service>/base/` | Rollout (blue-green), `app-active` / `app-preview` Services, `e2e` AnalysisTemplate |
| `apps/<service>/overlays/{test,prod}/` | Namespace, image tags, `argo-poc/app-sha`, NodePorts. CI and promotion change only these. |
| `argocd/services-appset.yaml` | ApplicationSet: one app `<service>-<env>` per `apps/*/overlays/*` folder |
| `argocd/` (rest) | AppProject, `root` (app-of-apps), notifications config |
| `services.yaml` | Service registry: app repo, main image, URLs |
| `.github/workflows/release.yaml` | Shared CI called by every app repo: build, push, deploy to test |
| `.github/workflows/on-deployed.yaml` | Records GitHub Deployments and opens prod promotion PRs |

## Setup from scratch

Prereqs: Docker Desktop, `brew install kind argocd kustomize argoproj/tap/kubectl-argo-rollouts`.

1. **Token:** a fine-grained PAT (owner `vibrant-ethan-test-org`; repos: this one and every app repo;
   permissions Contents, Pull requests, Deployments: read and write) saved to `~/.config/argo-poc/token`
   (`chmod 600`), and stored as secret `POC_PAT` in every repo:
   ```sh
   for r in argo-poc-gitops argo-poc-app argo-poc-api; do
     tr -d '[:space:]' < ~/.config/argo-poc/token | gh secret set POC_PAT -R vibrant-ethan-test-org/$r
   done
   ```
2. **Everything else:** `./bootstrap/install.sh`. It creates the cluster, installs Argo CD and Argo Rollouts,
   loads the token into `argocd-notifications-secret`, and applies `argocd/root.yaml`. All apps then come from Git.

GHCR images must be public (Org settings → Packages must allow public packages), or the cluster needs a pull secret.

Argo CD: https://localhost:8443, user `admin`, password:

```sh
kubectl --context kind-argo-poc -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Watch a rollout: `kubectl argo rollouts --context kind-argo-poc -n argo-poc-api-test get rollout app --watch`,
or open the app in Argo CD, click the `app` Rollout, then the **Rollout** tab.

## Adding a service

1. New app repo with a `ci.yaml` that calls
   `vibrant-ethan-test-org/argo-poc-gitops/.github/workflows/release.yaml@main` with its `service` name and `images`.
   Set the `POC_PAT` secret on it and add the repo to the PAT.
2. Here: `apps/<service>/base` and `overlays/{test,prod}` (unique NodePorts), and an entry in `services.yaml`.
   The ApplicationSet creates `<service>-test` and `<service>-prod` automatically.
3. After the first CI run, make the new GHCR package public, then set the prod overlay to the first tag.

## Demos (verified)

| Scenario | How | What happens |
|---|---|---|
| Happy path | Push an app change | Test goes blue-green, e2e passes, traffic switches; prod PR opens; merging deploys prod the same way |
| Broken release | Push a change that breaks the page but not `/healthz` | e2e fails on preview, rollout aborted, test keeps the old version, no PR |
| Independent services | Push to one app repo only | Only that service's test app changes and only its PR opens |
| Rollback (GitOps) | `git revert` the prod promotion commit | Prod returns to the previous version through blue-green + e2e |
| `kubectl argo rollouts undo` | Run it against prod | Argo CD self-heals the Rollout back to Git within seconds. With self-heal on, roll back in Git. |
| Self-heal | Scale the Rollout by hand | Argo CD restores `replicas: 2` within seconds |
| Disaster recovery | `kind delete cluster --name argo-poc && ./bootstrap/install.sh` | The whole platform and every service come back from Git |

## Lessons from building it

- **Notification race.** Right after a sync, Argo CD can still report the previous version's Healthy
  status before Rollouts starts the new one. The `on-deployed` trigger therefore requires
  `health.lastTransitionTime > operationState.finishedAt` (became Healthy after the sync).
- **Once per sync, not per commit.** With one repo for many services, every commit changes the revision of
  every app. The trigger uses `oncePer: operationState.syncResult.revision`, so it fires only for apps
  that actually synced.
- **Kustomize and Rollouts.** Kustomize does not know Rollout or AnalysisTemplate fields. `rollout-transform.yaml`
  (from Argo Rollouts) plus `images-transform.yaml` make name references, annotations and image tags work.
- **First deploy skips e2e.** A Rollout's first version has nothing to compare against and goes live directly.
- **Multi-arch images.** GitHub runners are amd64 and the kind node on Apple silicon is arm64, so CI builds both.
- **Polling.** GitHub cannot reach a laptop, so Argo CD polls every 30s (`timeout.reconciliation`).

## Teardown

```sh
kind delete cluster --name argo-poc
```
