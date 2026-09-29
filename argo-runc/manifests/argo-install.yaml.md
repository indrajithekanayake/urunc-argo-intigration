# argo-install.yaml is not committed

It is 12 MB of unmodified upstream YAML (192,343 lines, mostly 8 CRD schemas).
Fetch the exact version this lab used:

    curl -fsSL -o argo-install.yaml \
      https://github.com/argoproj/argo-workflows/releases/download/v4.1.4/install.yaml

Verified byte-identical to upstream v4.1.4 at the time of the experiment.
Apply with --server-side (its CRDs exceed the last-applied-configuration
annotation size limit):

    kubectl apply -n argo --server-side=true -f argo-install.yaml
