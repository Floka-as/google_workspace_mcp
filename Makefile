REGISTRY  := europe-north1-docker.pkg.dev/solvr-multitenant/internal-artifacts
IMAGE     := $(REGISTRY)/gws-mcp
TAG       := $(shell git rev-parse --short=7 HEAD)
NAMESPACE := mcphub
HOST      := gws.mcphub.no

.PHONY: sbom build push bump ship deploy status logs rollout smoke run-local

sbom: sbom.cdx.json

sbom.cdx.json: uv.lock pyproject.toml
	uv export --no-hashes --no-editable --no-emit-project --frozen > /tmp/gws-reqs.txt
	uvx --from cyclonedx-bom cyclonedx-py requirements /tmp/gws-reqs.txt -o $@ --of json

## build — container image tagged with the current commit
build:
	docker build -t $(IMAGE):$(TAG) .

## push — publish that image to Artifact Registry
push:
	docker push $(IMAGE):$(TAG)

## bump — point the kustomization at the current commit's image
## (sed rather than `kustomize edit`, which needs the standalone binary)
bump:
	sed -i 's|^\( *newTag: \).*|\1"$(TAG)"|' k8s/kustomization.yaml
	@grep -q 'newTag: "$(TAG)"' k8s/kustomization.yaml || { echo "bump failed"; exit 1; }
	@kubectl kustomize k8s | grep -q '$(IMAGE):$(TAG)' && echo "kustomization -> $(IMAGE):$(TAG)"

## ship — build, push, bump, and commit the tag. ArgoCD syncs it from main.
## Refuses a dirty tree, since TAG would then name a commit that is not what
## got built.
ship:
	@git diff-index --quiet HEAD -- || { echo "working tree dirty — commit first"; exit 1; }
	$(MAKE) build
	$(MAKE) push
	$(MAKE) bump
	@git diff --quiet k8s/kustomization.yaml || git commit -q -m "Ship $(TAG) to $(HOST)" k8s/kustomization.yaml
	@echo "shipped $(IMAGE):$(TAG) — push to main for ArgoCD to sync"

## deploy — apply the ArgoCD Application (one-time bootstrap)
deploy:
	kubectl apply -f k8s/app.yaml

## status — what is actually running
status:
	kubectl -n $(NAMESPACE) get deploy,pod,svc,ingress -l app=gws-mcp
	kubectl -n $(NAMESPACE) get onepassworditem oauth2-credentials-google
	@kubectl -n $(NAMESPACE) get deploy gws-mcp -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

## logs — tail the running pod
logs:
	kubectl -n $(NAMESPACE) logs -l app=gws-mcp --tail=100 -f

## rollout — restart to pick up rotated OAuth client credentials
rollout:
	kubectl -n $(NAMESPACE) rollout restart deployment/gws-mcp
	kubectl -n $(NAMESPACE) rollout status deployment/gws-mcp

## run-local — the deployed configuration, on localhost:8000, against a
## throwaway credentials dir. Needs GOOGLE_OAUTH_CLIENT_ID/SECRET in the env.
run-local:
	docker run --rm -p 8000:8000 \
	  -e MCP_ENABLE_OAUTH21=true \
	  -e WORKSPACE_MCP_HOST=0.0.0.0 \
	  -e WORKSPACE_MCP_TOOLS=calendar,gmail,drive \
	  -e WORKSPACE_EXTERNAL_URL=http://localhost:8000 \
	  -e OAUTHLIB_INSECURE_TRANSPORT=1 \
	  -e GOOGLE_OAUTH_CLIENT_ID -e GOOGLE_OAUTH_CLIENT_SECRET \
	  $(IMAGE):$(TAG)

## smoke — health, then an unauthenticated MCP call. A 401 carrying a
## WWW-Authenticate pointer is the expected, correct answer: OAuth 2.1 is on.
smoke:
	@curl -sS https://$(HOST)/health; echo
	@printf '%s' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"make-smoke","version":"0"}}}' \
	| curl -sS -i -X POST https://$(HOST)/mcp \
	    -H 'Content-Type: application/json' \
	    -H 'Accept: application/json, text/event-stream' \
	    --data-binary @- | head -20
	@curl -sS https://$(HOST)/.well-known/oauth-protected-resource/mcp | head -c 400; echo
