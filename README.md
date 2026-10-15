# argo-poc-gitops

Deployment config for the Argo CD + Argo Rollouts proof of concept. Argo CD reads only this repo.
App code and CI live in [argo-poc-app](https://github.com/vibrant-ethan-test-org/argo-poc-app).

```
push to argo-poc-app main
  → ci.yaml: build + push images to GHCR, commit tag to apps/argo-poc/overlays/test
  → Argo CD syncs app-test → Argo Rollouts: green up, e2e on preview, switch traffic
  → Argo CD Notifications → repository_dispatch → on-deployed.yaml
      → GitHub Deployment "test" on the app commit
      → PR "prod: argo-poc-app vX" updating overlays/prod (with app changelog)
  → merge PR → Argo CD syncs app-prod → blue-green + e2e again → Deployment "prod"
```

If e2e fails, Rollouts aborts, the old version keeps serving, `app-test` goes Degraded,
no notification fires and no prod PR is opened.

## Layout

| Path | What |
|---|---|
| `bootstrap/` | `kind-config.yaml` and `install.sh` (kind cluster, Argo CD, Argo Rollouts) |
| `apps/argo-poc/base/` | Rollout (blue-green), `app-active` / `app-preview` Services, `e2e` AnalysisTemplate |
| `apps/argo-poc/overlays/{test,prod}/` | Namespace, image tags, `argo-poc/app-sha`, NodePorts. CI and promotion change only these. |
| `argocd/` | AppProject, `app-test`, `app-prod`, `root` (app-of-apps), notifications config |
| `.github/workflows/on-deployed.yaml` | Records GitHub Deployments and opens prod promotion PRs |

## Setup from scratch

Prereqs: Docker Desktop, `brew install kind argocd kustomize argoproj/tap/kubectl-argo-rollouts`.

1. **Cluster:** `./bootstrap/install.sh`
2. **Token:** create a fine-grained PAT (owner `vibrant-ethan-test-org`, repos `argo-poc-app` and
   `argo-poc-gitops`, permissions Contents / Pull requests / Deployments: read and write).
   Save it to `~/.config/argo-poc/token` (`chmod 600`).
3. **Secrets:**
   ```sh
   for r in argo-poc-app argo-poc-gitops; do
     tr -d '[:space:]' < ~/.config/argo-poc/token | gh secret set POC_PAT -R vibrant-ethan-test-org/$r
   done
   tr -d '[:space:]' < ~/.config/argo-poc/token > /tmp/t && \
     kubectl --context kind-argo-poc -n argocd create secret generic argocd-notifications-secret \
       --from-file=github-token=/tmp/t --dry-run=client -o yaml \
     | kubectl --context kind-argo-poc apply --server-side --force-conflicts -f - ; rm /tmp/t
   ```
4. **Apps:** `kubectl --context kind-argo-poc apply -f argocd/root.yaml`. Everything else is managed from Git.

GHCR images must be public (Org settings → Packages must allow public packages), or the cluster needs a pull secret.

## URLs

| What | URL |
|---|---|
| Argo CD | https://localhost:8443 (user `admin`, password below) |
| Test live / preview | http://localhost:8081 / http://localhost:8082 |
| Prod live / preview | http://localhost:8091 / http://localhost:8092 |

```sh
kubectl --context kind-argo-poc -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Watch a rollout: `kubectl argo rollouts --context kind-argo-poc -n app-test get rollout app --watch`

## Demos (all verified)

| Scenario | How | What happens |
|---|---|---|
| Happy path | Push an app change | Test goes blue-green, e2e passes, traffic switches; prod PR opens ~10s later; merging deploys prod the same way |
| Broken release | Push a change that breaks the page but not `/healthz` | e2e fails on preview, rollout aborted, test keeps the old version, no PR |
| Rollback (GitOps) | `git revert` the prod promotion commit | Prod returns to the previous version through blue-green + e2e; a re-promotion PR opens because test still has a newer verified version |
| `kubectl argo rollouts undo` | Run it against prod | Argo CD self-heals the Rollout back to Git within seconds. With self-heal on, roll back in Git. |
| Self-heal | Scale the Rollout by hand | Argo CD restores `replicas: 2` within seconds |

## Lessons from building it

- **Notification race.** Right after a sync, Argo CD can still report the previous version's Healthy
  status before Rollouts starts the new one. The `on-deployed` trigger therefore requires
  `health.lastTransitionTime > operationState.finishedAt` (became Healthy after the sync).
- **Kustomize and Rollouts.** Kustomize does not know Rollout or AnalysisTemplate fields. `base/rollout-transform.yaml`
  (from Argo Rollouts) plus `base/images-transform.yaml` make name references, annotations and image tags work.
- **First deploy skips e2e.** A Rollout's first version has nothing to compare against and goes live directly.
- **Re-fires are normal.** The trigger fires once per Git revision, including unrelated commits. `on-deployed.yaml` is idempotent.
- **Multi-arch images.** GitHub runners are amd64 and the kind node on Apple silicon is arm64, so CI builds both.
- **Polling.** GitHub cannot reach a laptop, so Argo CD polls every 30s (`timeout.reconciliation`).

## Teardown

```sh
kind delete cluster --name argo-poc
```
