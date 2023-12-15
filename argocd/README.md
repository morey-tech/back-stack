# The BACK Stack - Argo CD

```
kustomize build argocd/ | kubectl apply -f -
argocd admin initial-password -n argocd
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
