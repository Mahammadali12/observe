# Local Kubernetes Observability Setup

This setup is intentionally simple for learning:

- Your app exports OTLP gRPC to the OpenTelemetry Collector.
- The Collector exports traces to VictoriaTraces with OTLP/HTTP.
- The Collector exposes metrics on a Prometheus scrape endpoint.
- VictoriaMetrics scrapes the Collector's Prometheus endpoint.
- No Jaeger component is deployed.

All manifests use the `default` namespace.

## 1. Deploy VictoriaTraces First

Apply only VictoriaTraces before changing the Collector. This proves trace storage is alive before anything sends data to it.

```bash
kubectl apply -f victoriatraces-pvc.yaml
kubectl apply -f victoriatraces-deployment.yaml
kubectl apply -f victoriatraces-service.yaml
```

Check the resources:

```bash
kubectl get pvc victoria-traces-data -n default
kubectl get deployment victoria-traces -n default
kubectl get pods -l app=victoria-traces -n default
kubectl get svc victoria-traces -n default
```

Expected shape:

```text
victoria-traces-data   Bound    ...
victoria-traces        1/1      ...
victoria-traces-...    1/1      Running
victoria-traces        ClusterIP ... 10428/TCP
```

Port-forward the internal Service:

```bash
kubectl port-forward -n default svc/victoria-traces 10428:10428
```

In another terminal:

```bash
curl -i localhost:10428/health
curl -i localhost:10428/select/vmui
```

Expected:

- `/health` should return an HTTP success response when the binary exposes it.
- `/select/vmui` should return HTML or another HTTP `200` response.

If VictoriaTraces is not healthy:

```bash
kubectl logs deployment/victoria-traces -n default
kubectl describe pod -l app=victoria-traces -n default
```

Common problems:

- `ImagePullBackOff`: check that `victoriametrics/victoria-traces:v0.9.3` exists from your cluster. For learning, temporarily change it to `victoriametrics/victoria-traces:latest`.
- `CrashLoopBackOff`: logs usually show a bad flag, bad storage path, or PVC mount issue.
- PVC stays `Pending`: make sure `victoriatraces-pv.yaml` was applied before the PVC and that both PV and PVC use `storageClassName: manual`.
- Talos error `mkdir /mnt/data: read-only file system`: Talos has a read-only root filesystem. These PVs now use `/var/lib/observability/...`, which lives under Talos' writable `/var` area.
- Port-forward timeout: make sure you forward the Service, `svc/victoria-traces`, not a pod name.

If you already created the old `/mnt/data` PV/PVC and the pod is failing, recreate the VictoriaTraces storage objects:

```bash
kubectl delete deployment victoria-traces -n default
kubectl delete pvc victoria-traces-data -n default
kubectl delete pv victoria-traces-pv
kubectl apply -f victoriatraces-pv.yaml
kubectl apply -f victoriatraces-pvc.yaml
kubectl apply -f victoriatraces-deployment.yaml
kubectl apply -f victoriatraces-service.yaml
```

## 2. Rebuild Your App With service.name

`otel.go` now sets the OpenTelemetry resource `service.name=observe`. VictoriaTraces indexes this value, so it is what you query traces by.

Build locally:

```bash
go build -o app .
```

Expected:

```text
# no output means success
```

Then rebuild and push your app image using your normal Docker Hub workflow:

```bash
docker build -t <your-dockerhub-user>/<your-image>:<tag> .
docker push <your-dockerhub-user>/<your-image>:<tag>
```

If you changed the image tag, update `deployment.yaml`, then deploy:

```bash
kubectl apply -f deployment.yaml
kubectl rollout status deployment/myapp -n default
```

Expected:

```text
deployment "myapp" successfully rolled out
```

## 3. Update And Restart The Collector

The Collector now:

- receives OTLP gRPC on `4317`
- receives OTLP HTTP on `4318`
- exports traces to `http://victoria-traces.default.svc.cluster.local:10428/insert/opentelemetry/v1/traces`
- exposes Prometheus metrics on `8889`

Run a Kubernetes dry run first:

```bash
kubectl apply --dry-run=client -f otel-collector-configmap.yaml -f otel-collector-deployment.yaml -f otel-collector-service.yaml
```

Apply the Collector changes:

```bash
kubectl apply -f otel-collector-configmap.yaml
kubectl apply -f otel-collector-deployment.yaml
kubectl apply -f otel-collector-service.yaml
kubectl rollout restart deployment/otel-collector -n default
kubectl rollout status deployment/otel-collector -n default
```

Check the Service:

```bash
kubectl get svc otel-collector -n default
```

Expected ports:

```text
4317/TCP, 4318/TCP, 8889/TCP
```

Check logs:

```bash
kubectl logs deployment/otel-collector -n default
```

Common problems:

- Export errors to VictoriaTraces: compare the endpoint path exactly with `/insert/opentelemetry/v1/traces`.
- Collector restart fails: check config syntax with `kubectl logs deployment/otel-collector -n default`.
- Metrics target later shows down: confirm Service port `8889` exists and the Collector pod is running.

## 4. Generate And Verify Traces

Send traffic to the app. If your app Service is still NodePort, use your existing access path. If you prefer port-forwarding:

```bash
kubectl port-forward -n default svc/myapp 8080:80
curl localhost:8080/rolldice/maqa
```

Now query VictoriaTraces:

```bash
kubectl port-forward -n default svc/victoria-traces 10428:10428
curl localhost:10428/select/jaeger/api/services
```

Expected after traffic:

```json
{
  "data": [
    "observe"
  ],
  "errors": null
}
```

Query traces by service:

```bash
curl "localhost:10428/select/jaeger/api/traces?service=observe&limit=5"
```

Expected:

- JSON response from the Jaeger-compatible API.
- At least one trace after app traffic and Collector export.

If `observe` does not appear:

- Confirm you rebuilt and redeployed the app image after the `service.name` change.
- Confirm `deployment.yaml` points at the exact pushed image, currently `mahammadalii12/observe:v2`.
- Confirm the running pod uses the new image:
  ```bash
  kubectl describe pod -l app=myapp -n default
  ```
- Confirm the running container has the service-name env vars:
  ```bash
  kubectl exec deployment/myapp -n default -- printenv | grep OTEL
  ```
- Check Collector logs for export errors.
- Generate traffic again and retry the query.

## 5. Deploy VictoriaMetrics

VictoriaMetrics uses Prometheus-compatible scrape config in `victoriametrics-scrape-configmap.yaml`. It scrapes:

```text
otel-collector.default.svc.cluster.local:8889
```

Apply it:

```bash
kubectl apply -f victoriametrics-scrape-configmap.yaml
kubectl apply -f victoriametrics-pvc.yaml
kubectl apply -f victoriametrics-deployment.yaml
kubectl apply -f victoriametrics-service.yaml
kubectl rollout status deployment/victoria-metrics -n default
```

Check resources:

```bash
kubectl get pvc victoria-metrics-data -n default
kubectl get pods -l app=victoria-metrics -n default
kubectl get svc victoria-metrics -n default
```

Expected shape:

```text
victoria-metrics-data   Bound    ...
victoria-metrics-...    1/1      Running
victoria-metrics        ClusterIP ... 8428/TCP
```

Port-forward:

```bash
kubectl port-forward -n default svc/victoria-metrics 8428:8428
```

Check scrape targets:

```bash
curl localhost:8428/targets
```

Expected:

- Target `otel-collector.default.svc.cluster.local:8889`
- Health/up status after the first scrape

Generate more app traffic:

```bash
curl localhost:8080/rolldice/maqa
curl localhost:8080/rolldice/maqa
curl localhost:8080/rolldice/maqa
```

Query the dice metric:

```bash
curl "localhost:8428/api/v1/query?query=dice_rolls_total"
```

If that returns no data, list metric names containing `dice`:

```bash
curl "localhost:8428/api/v1/label/__name__/values" | grep dice
```

The OpenTelemetry Collector's Prometheus exporter normalizes metric names, so the final name may differ slightly from the SDK name `dice.rolls`.

## 6. Useful Cleanup

Delete only the Victoria components:

```bash
kubectl delete -f victoriametrics-service.yaml -f victoriametrics-deployment.yaml -f victoriametrics-pvc.yaml -f victoriametrics-scrape-configmap.yaml
kubectl delete -f victoriatraces-service.yaml -f victoriatraces-deployment.yaml -f victoriatraces-pvc.yaml
```

This deletes the PVCs too, so stored metrics and traces are removed.
