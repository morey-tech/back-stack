#!/bin/bash
# import helpers
. scripts/common.sh

# configure ingress
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s 

# install crossplane
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm upgrade --install crossplane \
  --namespace crossplane-system \
  --create-namespace \
  crossplane-stable/crossplane \
  --set args='{--enable-external-secret-stores}' \
  --wait

# install vault ess plugin
helm upgrade --install ess-plugin-vault \
  oci://xpkg.upbound.io/crossplane-contrib/ess-plugin-vault \
  --namespace crossplane-system \
  --set-json podAnnotations='{"vault.hashicorp.com/agent-inject": "true", "vault.hashicorp.com/agent-inject-token": "true", "vault.hashicorp.com/role": "crossplane", "vault.hashicorp.com/agent-run-as-user": "65532"}'

# install back stack
kubectl apply -f crossplane/manifests/back-stack-configuration.yaml

# configure provider-helm for crossplane
waitfor default crd providerconfigs.helm.crossplane.io
kubectl wait crd/providerconfigs.helm.crossplane.io --for=condition=Established --timeout=1m
kubectl apply -f crossplane/manifests/helm-controlerconfig.yaml
kubectl apply -f crossplane/manifests/helm-providerconfig.yaml
kubectl apply -f crossplane/manifests/helm-crb.yaml

# configure provider-kubernetes for crossplane
waitfor default crd providerconfigs.kubernetes.crossplane.io
kubectl wait crd/providerconfigs.kubernetes.crossplane.io --for=condition=Established --timeout=1m
kubectl apply -f crossplane/manifests/kubernetes-controlerconfig.yaml
kubectl apply -f crossplane/manifests/kubernetes-providerconfig.yaml
kubectl apply -f crossplane/manifests/kubernetes-crb.yaml

# configure provider-azure for crossplane
waitfor default crd providerconfigs.azure.upbound.io
kubectl wait crd/providerconfigs.azure.upbound.io --for=condition=Established --timeout=1m
kubectl apply -f crossplane/manifests/azure-providerconfig.yaml

# configure provider-aws for crossplane
waitfor default crd providerconfigs.aws.upbound.io
kubectl wait crd/providerconfigs.aws.upbound.io --for=condition=Established --timeout=1m
kubectl apply -f crossplane/manifests/aws-providerconfig.yaml

# get config
loadenv ./.env

# deploy hub
waitfor default crd hubs.backstack.cncf.io
kubectl wait crd/hubs.backstack.cncf.io --for=condition=Established --timeout=1m
kubectl apply -f - <<-EOF
    apiVersion: backstack.cncf.io/v1alpha1
    kind: Hub
    metadata:
      name: hub
    spec: 
      parameters:
        clusterId: local
        repository: ${REPOSITORY}
        backstage:
          host: backstage-7f000001.nip.io
        argocd:
          host: argocd-7f000001.nip.io
        vault:
          host: vault-7f000001.nip.io
EOF

# deploy secrets
waitfor default ns argocd
kubectl create -f - <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: clusters
      namespace: argocd
      labels:
        argocd.argoproj.io/secret-type: repository
    stringData:
      type: git
      url: ${REPOSITORY}
      password: ${GITHUB_TOKEN}
      username: back-stack
EOF

waitfor default ns backstage
kubectl create -f - <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: backstage
      namespace: backstage
    stringData:
      GITHUB_TOKEN: ${GITHUB_TOKEN}
      VAULT_TOKEN: ${VAULT_TOKEN}
EOF

kubectl create -f - <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: azure-secret
      namespace: crossplane-system
    stringData:
      credentials: |
        ${AZURE_CREDENTIALS}
EOF

kubectl create -f - <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: aws-secret
      namespace: crossplane-system
    stringData:
      credentials: |
        [default]
        aws_access_key_id=${AWS_ACCESS_KEY_ID}
        aws_secret_access_key=${AWS_SECRET_ACCESS_KEY}
        aws_session_token=${AWS_SESSION_TOKEN}
EOF


waitfor argocd secret argocd-initial-admin-secret
ARGO_INITIAL_PASSWORD=$(kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

# configure vault
kubectl wait -n vault pod/vault-0 --for=condition=Ready --timeout=1m
kubectl -n vault exec -i vault-0 -- vault auth enable kubernetes
kubectl -n vault exec -i vault-0 -- sh -c 'vault write auth/kubernetes/config \
        token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
        kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
        kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'
kubectl -n vault exec -i vault-0 -- vault policy write crossplane - <<EOF
path "secret/data/*" {
    capabilities = ["create", "read", "update", "delete"]
}
path "secret/metadata/*" {
    capabilities = ["create", "read", "update", "delete"]
}
EOF
kubectl -n vault exec -i vault-0 -- vault write auth/kubernetes/role/crossplane \
    bound_service_account_names="*" \
    bound_service_account_namespaces=crossplane-system \
    policies=crossplane \
    ttl=24h

# restart ess pod
kubectl get -n crossplane-system pods -o name | grep ess-plugin-vault | xargs kubectl delete -n crossplane-system 

# ready to go!
echo ""
echo "
Your BACK Stack is ready!

Backstage: https://backstage-7f000001.nip.io
ArgoCD: https://argocd-7f000001.nip.io
  username: admin
  password ${ARGO_INITIAL_PASSWORD}
"
