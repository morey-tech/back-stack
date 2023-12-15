> The Crossplane deployment starts with the crossplane-init container. The init container installs the Crossplane Custom Resource Definitions into the Kubernetes cluster.

The fact that the `init` container on the Crossplane deployment creates the CRDs in the cluster impacts the sync of Argo CD Applications that create the CRs from those CRDs. 

The sync will fail and retry until those CRDs are present, but if the crossplane deployment is in the same Applicaiton as on of the CRDs that the `init` container creates, it will never apply the `crossplane` deployment. Since it won't apply anything until the CRDs exist for the resources in the Application.

Normally the Application would contain the CRDs as manifests from the source which prevents this issue. The Application is aware of the CRDs requried and applies them first, preventing the sync from getting stuck waiting on them.

Using a lower sync wave for the deployment (or higher sync wave for the configs) doesn't seem to help either as the Application is still checking if the CRDs exist even if the resources are included in the wave.

So the workaround is to have 3 Applications:
1. Deploy Crossplane Helm Chart. (`crossplane/manifests/kustomization.yaml`)
2. Deploy Crossplane Configuration with provider dependencies.  (`crossplane/manifests/configurations`)
3. Deploy Crossplane ProviderConfigs for those providers.  (`crossplane/manifests/provider-configs`)
