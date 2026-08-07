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
| Auth           | Resource server only (`EXTERNAL_OAUTH21_PROVIDER=true`) — Solvei brokers |

## How auth works here

**Solvei owns the Google OAuth flow; this server only validates the result.**

Solvei's `MCPServer.AuthType.AUTHORIZATION_CODE` already does the whole
authorization-code dance — org-wide client registration, per-user
`MCPServerConnection`, `ensure_access_token` refreshing inside a 60s margin,
`access_type=offline` so a refresh token actually gets issued. It hands the ADK
a fresh `ya29.*` access token, which arrives here as
`Authorization: Bearer ya29…`.

So this server issues nothing. `/authorize`, `/token`, `/register` and
`/oauth2callback` **do not exist** (they 404), and **no redirect URI needs
registering against `gws.mcphub.no`** — Solvei's own callback is the only one
Google ever sees. `ensure_session_from_access_token` builds
`Credentials(token=<bearer>, refresh_token=None)` and explicitly skips session
storage in this mode, so the pod holds no user credentials at all. Same shape as
fiken-mcp's `oauth2_passthrough`.

`/.well-known/oauth-protected-resource/mcp` advertises Google
(`https://accounts.google.com/`) as the authorization server, so a
spec-compliant client that *isn't* Solvei still learns where to go — it just has
to obtain the token itself.

### The one thing to know before widening access

Token validation is a **userinfo call**. It proves the token is live and whose it
is; it does **not** check that the token was minted for our client. Any valid
Google access token is therefore accepted, acting as its own holder within its
own granted scopes. Nobody can reach another user's data, but the public
endpoint is usable by any Google user.

If that stops being acceptable, the cheapest fix is to drop the ingress
entirely: `hosting-solvei-dev` and `hosting-solvei-multitenant` run in this same
cluster, so the ADK can call
`http://gws-mcp.mcphub.svc.cluster.local:8000/mcp` with no public surface at
all. An ingress source-range allowlist is the middle option.

## One-time setup before the first deploy

1. **Google Cloud Console** — nothing for this host. The OAuth client behind
   `solvr-multitenant-oauth2-dev` needs Calendar, Gmail and Drive scopes on its
   consent screen and Solvei's callback registered, both of which the Solvei
   side already requires. The client id and secret still reach this pod (they
   are passed to the `Credentials` object used for validation), which is why the
   `OnePasswordItem` is still here.

2. **DNS/TLS** — nothing to do by hand. external-dns creates the A record from
   the ingress; cert-manager issues the cert via `letsencrypt-prod`.

3. **Bootstrap ArgoCD** (once):

   ```sh
   make deploy      # kubectl apply -f k8s/app.yaml
   ```

   ArgoCD needs its own read access to this fork, the same per-repo deploy-key
   arrangement every other app here uses. Already done for this repo — the key
   is the `argocd-gws-mcp (read-only)` deploy key on the GitHub side and the
   `repo-gws-mcp` Secret (labelled `argocd.argoproj.io/secret-type=repository`)
   in `kube-argocd`. Without it the Application reports
   `ComparisonError: ... SSH_AUTH_SOCK not-specified`. To rotate: generate a new
   ed25519 pair, `gh repo deploy-key add`, replace `sshPrivateKey` in the Secret.

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

One deliberate deviation from `fiken-mcp`:

- **The container command is overridden** to `/app/.venv/bin/python main.py`.
  Upstream's `CMD` shells out to `uv run`, which wants a writable `/app`;
  calling the venv's python directly is what lets `readOnlyRootFilesystem: true`
  stand. `--tools` is not passed — `WORKSPACE_MCP_TOOLS` in the env does the
  same job and keeps the selection visible in the manifest.

## Verified locally

Read-only rootfs, non-root uid 1000, writable `/data` and `/tmp` only:

```
GET  /health                                    200 {"status":"healthy",...}
POST /mcp            (no token)                 401 + www-authenticate: Bearer resource_metadata=...
GET  /.well-known/oauth-protected-resource/mcp  200 authorization_servers: ["https://accounts.google.com/"]
GET  /authorize, /token, /register              404  (resource-server mode issues nothing)
tools registered                                38 (calendar + gmail + drive)
```

`make run-local` reproduces that against `localhost:8000`.
