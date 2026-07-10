# Makefile — build, push, and release the observe app + Helm chart
#
# Usage:
#   make release TAG=v5
#   make release                # auto-reads TAG from observe-chart/values.yaml
#
# Prerequisites: docker, helm, git

IMAGE_REPO := mahammadalii12/observe
CHART_DIR  := observe-chart
HELM_URL   := https://mahammadali12.github.io/observe

# Extract TAG from values.yaml if not provided on the command line
TAG ?= $(shell grep '^    tag:' $(CHART_DIR)/values.yaml | head -1 | awk '{print $$2}' | tr -d '"' | tr -d "'")

.PHONY: release
release:
	@if [ -z "$(TAG)" ]; then \
		echo "ERROR: TAG is empty. Pass it explicitly: make release TAG=v5"; \
		exit 1; \
	fi
	@echo "=== Releasing $(IMAGE_REPO):$(TAG) ==="
	@echo "[1/4] Building Docker image..."
	docker build -t $(IMAGE_REPO):$(TAG) .
	@echo "[2/4] Pushing Docker image..."
	docker push $(IMAGE_REPO):$(TAG)
	@echo "[3/4] Updating Helm chart source on master..."
	sed -i 's/^    tag: .*/    tag: $(TAG)/' $(CHART_DIR)/values.yaml
	git add $(CHART_DIR)/values.yaml
	git commit -m 'chore: bump app image tag to $(TAG)' || true
	git push origin master
	@echo "[4/4] Packaging and publishing chart to gh-pages..."
	helm package $(CHART_DIR)/ --destination /tmp
	git checkout gh-pages
	cp /tmp/observe-0.1.0.tgz .
	rm -rf $(CHART_DIR)/
	helm repo index . --url $(HELM_URL)
	git config user.name github-actions
	git config user.email github-actions@github.com
	git add observe-0.1.0.tgz index.yaml
	git commit -m 'chore: release observe-$(TAG)'
	git push origin gh-pages
	git checkout master
	@echo "=== Done. Deploy with: helm upgrade observe observe/observe ==="
