# --- Ingress (ingress-nginx) / Gateway API (Envoy Gateway) install for 'saas cluster create --expose-mode'.

# _saas_cluster_install_ingress_nginx NAME
_saas_cluster_install_ingress_nginx() {
    local name="$1"
    local ctx="kind-${name}"

    _saas_log_step "Installing ingress-nginx on '${name}' via Helm..."
    timeout 30 helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1
    timeout 30 helm repo update ingress-nginx >/dev/null 2>&1
    # hostPort.enabled=true plus the control-plane nodeSelector/tolerations
    # replicate ingress-nginx's own official manifest
    # "deploy/static/provider/kind/deploy.yaml" (the controller listens
    # directly on the control-plane node's own 80/443 ports, bypassing the
    # Service) but installed via Helm, same as MetalLB and csi-driver-nfs
    # elsewhere in this service.
    helm install ingress-nginx ingress-nginx/ingress-nginx \
        --kube-context "$ctx" \
        -n ingress-nginx --create-namespace --timeout 180s \
        --set controller.hostPort.enabled=true \
        --set controller.service.type=ClusterIP \
        --set-string controller.nodeSelector."ingress-ready"=true \
        --set-string controller.nodeSelector."kubernetes\.io/os"=linux \
        --set controller.tolerations[0].key=node-role.kubernetes.io/control-plane \
        --set controller.tolerations[0].operator=Exists \
        --set controller.tolerations[0].effect=NoSchedule \
        || { _saas_log_err "Failed to install ingress-nginx."; return 1; }

    # Same reason as _saas_cluster_install_metallb/_saas_cluster_setup_storage_nfs:
    # "helm install" without "--wait" doesn't block, so this waits
    # explicitly with a progress message.
    _saas_log_wait "Waiting for ingress-nginx's controller to become available (can take up to 3 min)..."
    kubectl --context "$ctx" -n ingress-nginx rollout status --timeout=180s deployment/ingress-nginx-controller \
        || { _saas_log_err "ingress-nginx's controller never became available."; return 1; }

    # The Deployment being Ready doesn't guarantee the admission-webhook
    # Service's Endpoints are already populated (a known ingress-nginx
    # race, the same class of problem already documented above for
    # MetalLB's webhook): applying an Ingress right after this point can
    # fail with "dial tcp ...: connect: connection refused" against
    # ingress-nginx-controller-admission. Explicitly wait for the
    # Endpoints to have at least one address before considering the
    # install done.
    kubectl --context "$ctx" -n ingress-nginx wait --for=jsonpath='{.subsets[0].addresses[0].ip}' --timeout=60s endpoints/ingress-nginx-controller-admission \
        || { _saas_log_err "ingress-nginx's admission-webhook Endpoints never got populated."; return 1; }

    _saas_log_ok "ingress-nginx ready (hostPort 80/443 on the control-plane node)."
}

# _saas_cluster_render_gateway_api_resources NAME
_saas_cluster_render_gateway_api_resources() {
    local name="$1"
    GW_NAME="${name}-gw" \
        envsubst '${GW_NAME}' <<'EOF'
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: ${GW_NAME}-proxy-config
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: NodePort
        # Without this patch, Kubernetes assigns a random nodePort from the
        # 30000-32767 range instead of the fixed 30080 'extraPortMappings'
        # expects (confirmed live). The port's name ("http-30080") is
        # derived by Envoy Gateway from the Gateway's own listener port
        # (spec.listeners[].port below); if that port changes, this name
        # needs updating too.
        patch:
          type: StrategicMerge
          value:
            spec:
              ports:
                - name: http-30080
                  port: 30080
                  nodePort: 30080
                  protocol: TCP
      envoyDeployment:
        pod:
          nodeSelector:
            ingress-ready: "true"
          tolerations:
            - key: node-role.kubernetes.io/control-plane
              operator: Exists
              effect: NoSchedule
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: ${GW_NAME}-class
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: ${GW_NAME}-proxy-config
    namespace: envoy-gateway-system
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GW_NAME}
  namespace: default
spec:
  gatewayClassName: ${GW_NAME}-class
  listeners:
    - name: http
      protocol: HTTP
      port: 30080
      allowedRoutes:
        namespaces:
          from: Same
EOF
}

# _saas_cluster_install_gateway_api NAME
_saas_cluster_install_gateway_api() {
    local name="$1"
    local ctx="kind-${name}"

    # Envoy Gateway's own chart already installs the Gateway API CRDs
    # (standard channel) as part of its own "helm install" - applying them
    # again by hand separately (kubectl apply of standard-install.yaml)
    # breaks with a server-side-apply conflict: the chart uses its own
    # field manager and collides with "kubectl-client-side-apply"'s
    # (confirmed live). No separate step needed.
    _saas_log_step "Installing Envoy Gateway on '${name}' via Helm (includes the Gateway API CRDs)..."
    helm install eg oci://docker.io/envoyproxy/gateway-helm \
        --kube-context "$ctx" \
        -n envoy-gateway-system --create-namespace --timeout 180s \
        || { _saas_log_err "Failed to install Envoy Gateway."; return 1; }

    _saas_log_wait "Waiting for Envoy Gateway's controller to become available (can take up to 3 min)..."
    kubectl --context "$ctx" -n envoy-gateway-system rollout status --timeout=180s deployment/envoy-gateway \
        || { _saas_log_err "Envoy Gateway's controller never became available."; return 1; }

    _saas_log_step "Configuring GatewayClass/EnvoyProxy/Gateway (fixed NodePort 30080/30443)..."
    local gw_yaml
    gw_yaml="$(_saas_cluster_render_gateway_api_resources "$name")"
    printf '%s\n' "$gw_yaml" | kubectl --context "$ctx" apply -f - \
        || { _saas_log_err "Failed to apply GatewayClass/EnvoyProxy/Gateway."; return 1; }

    _saas_log_wait "Waiting for Gateway '${name}-gw' to become Programmed..."
    kubectl --context "$ctx" -n default wait --for=condition=Programmed --timeout=120s gateway/"${name}-gw" \
        || { _saas_log_err "The Gateway never became Programmed."; return 1; }

    _saas_log_ok "Gateway API (Envoy Gateway) ready (NodePort 30080/30443 on the control-plane node)."
}
