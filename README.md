# argo-poc-gitops

Deployment config for the Argo CD + Argo Rollouts + Kargo proof of concept. Argo CD reads only this repo.
Each service's code and CI live in its own repo; all of them deploy through this one.

> The version without Kargo (CI commits to test, Argo CD Notifications open prod PRs) is on the
> [`argo-only`](https://github.com/vibrant-ethan-test-org/argo-poc-gitops/tree/argo-only) branch.

Three local kind clusters:

```
 kind-argo-mgmt   Argo CD (one UI) + ApplicationSet + Rollouts UI extension
                  Kargo (promotion UI, Warehouses, Stages)
      │  Kubernetes API over the Docker "kind" network (https://argo-<env>-control-plane:6443)
      ├────────► kind-argo-test   Argo Rollouts + argo-poc-test, argo-poc-api-test
      └────────► kind-argo-prod   Argo Rollouts + argo-poc-prod, argo-poc-api-prod
```

| UI | URL | Login |
|---|---|---|
| Argo CD | https://localhost:8443 | `admin` / `admin` |
| Kargo | http://localhost:8444 | password `admin` |

Both UIs listen on 127.0.0.1 only, so the fixed passwords are not reachable from your network.

| Service | App repo | Kargo Project | Test | Prod |
|---|---|---|---|---|
| `argo-poc` (web page) | [argo-poc-app](https://github.com/vibrant-ethan-test-org/argo-poc-app) | `argo-poc` | http://localhost:8081 | http://localhost:8091 |
| `argo-poc-api` (JSON API) | [argo-poc-api](https://github.com/vibrant-ethan-test-org/argo-poc-api) | `argo-poc-api` | http://localhost:8181/api/info | http://localhost:8191/api/info |

Preview (green) URLs are the same ports + 1 (8082, 8092, 8182, 8192).

## How a release flows

```
push to an app repo's main
  → its ci.yaml builds + pushes multi-arch images to GHCR as v0.2.<run> (e2e image first, same tag),
    with the app commit as an image annotation. CI does nothing else.
  → Kargo Warehouse sees the new tag (polls GHCR every 30s) → new Freight
  → Stage test (auto-promotion): Kargo commits the tag + app-sha to apps/<service>/overlays/test on main,
    pins Argo CD app <service>-test to that commit
  → Argo CD syncs → Argo Rollouts: green up, e2e on preview, switch traffic
  → Kargo sees the app Healthy at that commit → Freight "verified in test"
  → after 1 minute in test (soak), Stage prod auto-promotes it → same steps for overlays/prod
```

Deploying is still a Git commit that Argo CD applies. Kargo decides **when** to write it (automatically, unless a
Stage is held) and only lets prod have Freight that passed test and soaked there for 1 minute. Commits are authored by `kargo`
and say which Freight and who promoted it.

If e2e fails, Rollouts aborts and the old version keeps serving. The app goes Degraded, the Kargo Stage goes
Unhealthy, the Freight is never verified, and Kargo refuses to promote it to prod ("Freight is not available to
this Stage"). Pushing a fix produces new Freight that auto-promotes to test and replaces it.

## Holding a release

Both Stages auto-promote by default. `autoPromotionEnabled` in a ProjectConfig controls promotion *into* the Stage
it names. Ways to hold (all verified):

| Goal | How | Visible where | Undo |
|---|---|---|---|
| Keep one build in test for manual testing | Kargo UI: drag that (older) build onto test → Promote. Kargo records a hold | Kargo: ⏸ on the Stage card; open the Stage for an **Auto-promotion paused** banner (who, when, which build) | **Resume** in that banner |
| Hold prod (or any Stage): no new builds go in | Kargo UI: Project → Settings → ProjectConfig, `autoPromotionEnabled: false` for that Stage | Hard to see: only the small ⚡ next to the Stage name disappears, and the editor hides `false` values | Set it back to `true` |

Kargo's built-in hold cannot freeze prod at its current build (it only holds when you promote something other
than the newest build), so prod holds use the ProjectConfig switch. A manual Promote still works while a Stage is
held. Argo CD sync windows are deliberately not used: Kargo would still commit to Git and then show the promotion
as Running with no reason, which is confusing.

The 1-minute soak applies to manual promotion to prod too; lower `requiredSoakTime` in `kargo/<service>.yaml`
for a faster hotfix path. The ProjectConfig in Git only sets starting values; Argo CD ignores later changes to
`promotionPolicies` (`argocd/kargo.yaml`). Kargo's own "promotion windows" are Kargo Enterprise only.

## Layout

| Path | What |
|---|---|
| `bootstrap/` | `kind-{mgmt,test,prod}.yaml`, `install.sh` (three clusters, Argo CD, Argo Rollouts, UI extension, cert-manager, Kargo, cluster registration, root app), `kargo-values.yaml` |
| `bases/bluegreen-service/` | Shared by every service: Rollout (blue-green), `app-active` / `app-preview` Services, `e2e` AnalysisTemplate, with placeholder images `app` and `e2e` |
| `apps/<service>/base/` | One `kustomization.yaml`: points at the shared base and sets the service's name label and real image names (plus anything only this service needs, such as the API's `/e2e` command) |
| `apps/<service>/overlays/{test,prod}/` | Namespace, image tags, `argo-poc/app-sha`, NodePorts. Only Kargo changes these. |
| `argocd/services-appset.yaml` | ApplicationSet: one app `<service>-<env>` per `apps/*/overlays/*` folder, deployed to cluster `<env>`, authorized for Kargo Stage `<service>:<env>` |
| `argocd/kargo.yaml` | Argo CD app that syncs `kargo/` |
| `argocd/` (rest) | AppProject, `root` (app-of-apps) |
| `kargo/<service>.yaml` | Kargo Project, starting auto-promotion switches, Warehouse, Stages `test` and `prod` (1-minute soak) |
| `kargo/update-overlay-task.yaml` | The promotion steps every Stage runs: clone, set image tags + app-sha, commit, push, sync the Argo CD app |
| `.github/workflows/release.yaml` | Optional shared CI an app repo can call to build and push its images (the current app repos have their own `ci.yaml`) |

## Setup from scratch

Prereqs: Docker Desktop, `brew install kind argocd kustomize helm argoproj/tap/kubectl-argo-rollouts`.

1. **Token:** a fine-grained PAT (owner `vibrant-ethan-test-org`, repo `argo-poc-gitops`, Contents: read and write)
   saved to `~/.config/argo-poc/token` (`chmod 600`). Kargo uses it to push promotions. App repos need no secrets.
2. **Everything else:** `./bootstrap/install.sh` (2–3 minutes; longer the first time while images download).
   It creates the three clusters, installs Argo CD on argo-mgmt and Argo Rollouts on test and prod, installs
   cert-manager and Kargo, registers test and prod with Argo CD, stores the token as Kargo's git credential
   (`kargo-shared-resources/gitops-repo`), and applies `argocd/root.yaml`. All apps and Kargo pipelines then
   come from Git. Safe to re-run if a step times out.

GHCR images must be public (Org settings → Packages must allow public packages), or the clusters and Kargo
need pull credentials.

Watch a rollout: `kubectl argo rollouts --context kind-argo-test -n argo-poc-api-test get rollout app --watch`,
or open the app in Argo CD, click the `app` Rollout, then the **Rollout** tab.

## Adding a service

1. New app repo whose CI pushes SemVer tags (`vX.Y.Z`) to GHCR, with the e2e image under the same tag and the
   `org.opencontainers.image.revision` index annotation (Kargo copies it to `argo-poc/app-sha`). It can call
   `.github/workflows/release.yaml@main` here, or have its own `ci.yaml` like argo-poc-app and argo-poc-api.
2. Here: `apps/<service>/base/kustomization.yaml` (copy one; set the label and image names; no Rollout to copy)
   and `overlays/{test,prod}` (unique NodePorts), port mappings in
   `bootstrap/kind-test.yaml` and `kind-prod.yaml` (needs a cluster rebuild), and `kargo/<service>.yaml`
   (copy one; set the image and `e2eImage`). The ApplicationSet creates `<service>-test` and `<service>-prod`.
3. After the first CI run, make the new GHCR package public.

## Demos (verified)

| Scenario | How | What happens |
|---|---|---|
| Happy path | Push an app change | Kargo auto-promotes to test, blue-green + e2e pass, Freight verified; 1 minute later prod auto-promotes the same way |
| Hold test | Promote an older build to test in the UI | Kargo records a hold; new builds wait until **Resume** |
| Broken release | Push a change that breaks the page but not `/healthz` | e2e fails on preview, rollout aborted, test keeps the old version, Stage Unhealthy, Kargo will not promote it to prod |
| Fix forward | Push the fix | New Freight auto-promotes to test and becomes verified |
| Rollback | Kargo UI: promote an older verified Freight to prod | Kargo commits the old tag; blue-green + e2e as usual |
| Independent services | Push to one app repo only | Only that service's Kargo Project gets new Freight |
| `kubectl argo rollouts undo` | Run it against prod | Argo CD self-heals the Rollout back to Git within seconds. Roll back through Kargo instead. |
| Self-heal | Scale the Rollout by hand | Argo CD restores `replicas: 2` within seconds |
| Separate clusters | Release a change | Test's blue-green and e2e run on argo-test, prod's on argo-prod; Argo CD and Kargo on argo-mgmt drive both |
| Disaster recovery | Delete the clusters, run `./bootstrap/install.sh` | Clusters, apps and Kargo pipelines come back from Git. Kargo's Freight history does not; it starts from the newest images. |

## Lessons from building it

- **Pin the app to Kargo's commit.** Kargo's health check needs the Argo CD app synced to exactly the commit it
  pushed. All services share `main`, so another service's later commit would move the app's revision and make the
  Stage look unhealthy. `argocd-update` therefore sets `targetRevision` to the commit, and the ApplicationSet
  ignores `targetRevision` differences. A side effect: editing an overlay by hand on `main` does not deploy;
  changes go through Kargo.
- **Commit SHA for e2e.** Kargo reads OCI *annotations* on the image index, not image labels, so app CI
  adds `index:org.opencontainers.image.revision`. The promotion copies it into `argo-poc/app-sha`.
- **Readable tags.** Without an explicit image list, `kustomize-set-image` writes digests. The task names each
  image with its tag.
- **Pairing images.** The web app's main and e2e images come from one CI run; the Warehouse only creates
  Freight when both tags match (`freightCreationCriteria`).
- **Empty promotion variables count as missing.** The API passes its own image as `e2eImage`, and the task skips
  the second image step when they are the same.
- **No early "verified".** Kargo keeps the Stage Progressing while the Rollout runs and marks Freight verified
  only after e2e passed and traffic switched, so the Rollouts e2e gate also gates prod.
- **Promotion timeouts.** During a slow-network rebuild one `argocd-update` step timed out after 5 minutes
  waiting for Argo CD to start the sync. Re-promoting the same Freight fixed it.
- **Notification race (argo-only branch).** Argo CD can briefly report the previous version's Healthy status
  right after a sync; the Notifications trigger had to require `health.lastTransitionTime > operationState.finishedAt`.
- **Kustomize and Rollouts.** Kustomize does not know Rollout or AnalysisTemplate fields. `rollout-transform.yaml`
  (from Argo Rollouts) plus `images-transform.yaml` make name references, annotations and image tags work.
- **First deploy skips e2e.** A Rollout's first version has nothing to compare against and goes live directly.
- **Multi-arch images.** GitHub runners are amd64 and the kind node on Apple silicon is arm64, so CI builds both.
- **Polling.** GitHub cannot reach a laptop, so Argo CD polls Git every 30s and Kargo polls GHCR every 30s.
- **Cluster addresses.** `localhost` ports work from your Mac but not from pods. Argo CD reaches test and prod
  by their node names on the shared Docker network (`argo-test-control-plane:6443`), which are in the API certificates.

## Teardown

```sh
for c in mgmt test prod; do kind delete cluster --name argo-$c; done
```
