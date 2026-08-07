# Deploying to gws.mcphub.no

Floka's fork of [taylorwilsdon/google_workspace_mcp](https://github.com/taylorwilsdon/google_workspace_mcp),
deployed the same way as `fiken-mcp`: a container in Artifact Registry, manifests
in `k8s/`, ArgoCD syncing them from this fork's `main`.

|                |                                                                       |
| -------------- | --------------------------------------------------------------------- |
| Host           | `https://gws.mcphub.no`                                               |
| MCP endpoint   | `https://gws.mcphub.no/mcp` (streamable HTTP)                         |
| Cluster        | `solvr-multitenant-gke`, namespace `mcphub`                           |
| Image          | `europe-north1-docker.pkg.dev/solvr-multitenant/internal-artifacts/gws-mcp` |
| Tools exposed  | `calendar`, `gmail`, `drive` — 38 tools                               |
| Auth           | OAuth 2.1 (`MCP_ENABLE_OAUTH21=true`), per-caller Google consent      |

## How auth works here

The pod holds only the **OAuth client** credentials — id and secret from the
1Password item `solvr-multitenant-oauth2-dev`, the same one hosting-solvei-dev
uses. It holds no user's tokens at rest beyond an ephemeral volume.

Each MCP client discovers the authorization server from the 401 on `/mcp`,
dynamically registers itself at `/register`, and sends its user through Google's
consent screen. That is what makes a public ingress defensible: an
unauthenticated caller reaches the endpoint and can do nothing.

Because credentials live on an `emptyDir`, **every restart forces re-consent**.
Swap in a PVC (keeping `replicas: 1`) if that becomes annoying.

## One-time setup before the first deploy

1. **Google Cloud Console** — on the OAuth client behind
   `solvr-multitenant-oauth2-dev`, add the authorized redirect URI:

   ```
   https://gws.mcphub.no/oauth2callback
   ```

   Nothing else works until this exact string is registered.

2. **Consent screen scopes** — Calendar, Gmail and Drive scopes must be on the
   client's consent screen. Widening `WORKSPACE_MCP_TOOLS` later widens the
   requested scopes, and every user has to re-consent.

3. **DNS/TLS** — nothing to do by hand. external-dns creates the A record from
   the ingress; cert-manager issues the cert via `letsencrypt-prod`.

4. **Bootstrap ArgoCD** (once):

   ```sh
   make deploy      # kubectl apply -f k8s/app.yaml
   ```

## Shipping a change

```sh
make ship          # build + push + bump k8s/kustomization.yaml + commit the tag
git push           # ArgoCD syncs from main
make status        # what is actually running
make smoke         # /health, then an unauthenticated /mcp -> expect 401
make logs
```

`make ship` refuses a dirty tree: the tag names a commit, and it has to be the
commit that got built.

## Pulling in upstream

```sh
git fetch upstream
git merge upstream/main
make ship && git push
```

Merging alone changes nothing in the cluster — the image tag in
`k8s/kustomization.yaml` is what moves.

## What is in `k8s/`

| File                   | Purpose                                                        |
| ---------------------- | -------------------------------------------------------------- |
| `app.yaml`             | ArgoCD Application. Applied out-of-band, not part of the sync.  |
| `deployment.yaml`      | The pod. Read-only rootfs, non-root, ephemeral `/data`.         |
| `service.yaml`         | ClusterIP :8000.                                                |
| `ingress.yaml`         | nginx + cert-manager for `gws.mcphub.no`.                       |
| `onepassworditem.yaml` | Syncs the Google OAuth client into a Secret.                    |
| `kustomization.yaml`   | Ties them together and pins the image tag.                      |

Two deliberate deviations from `fiken-mcp`:

- **The whole host is routed**, not just `/mcp`. OAuth 2.1 needs
  `/.well-known/oauth-*`, `/authorize`, `/token`, `/register` and
  `/oauth2callback`, and FastMCP's OAuth proxy owns those routes, so
  enumerating them in the ingress would rot on an upstream bump.
- **The container command is overridden** to `/app/.venv/bin/python main.py`.
  Upstream's `CMD` shells out to `uv run`, which wants a writable `/app`;
  calling the venv's python directly is what lets `readOnlyRootFilesystem: true`
  stand. `--tools` is not passed — `WORKSPACE_MCP_TOOLS` in the env does the
  same job and keeps the selection visible in the manifest.

## Verified locally

Read-only rootfs, non-root uid 1000, writable `/data` and `/tmp` only:

```
GET  /health                                  200 {"status":"healthy",...}
POST /mcp            (no token)               401 + www-authenticate: Bearer resource_metadata=...
GET  /.well-known/oauth-authorization-server  200
POST /register                                201
tools registered                              38 (calendar + gmail + drive)
```

`make run-local` reproduces that against `localhost:8000`.
