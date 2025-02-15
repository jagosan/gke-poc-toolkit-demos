#!/usr/bin/env bash

set -Euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

while getopts p:r:t: flag
do
    case "${flag}" in
        p) PROJECT_ID=${OPTARG};;
        r) SYNC_REPO=${OPTARG};;
        t) PAT_TOKEN=${OPTARG};;
    esac
done

echo "::Variable set::"
echo "PROJECT_ID: ${PROJECT_ID}"
echo "SYNC_REPO: ${SYNC_REPO}"

### ArgoCD Install###
echo "Setting up ArgoCD on the mccp cluster including configure it for GKE Ingress."
echo "Creating a global public IP for the ArgoCD."
if [[ $(gcloud compute addresses describe argocd-ip --global --project ${PROJECT_ID}) ]]; then
  echo "ArgoCD IP already exists."
else
  echo "Creating ArgoCD IP."
  gcloud compute addresses create argocd-ip --global --project ${PROJECT_ID}
fi
export GCLB_IP=$(gcloud compute addresses describe argocd-ip --project ${PROJECT_ID} --global --format="value(address)")
echo -e "GCLB_IP is ${GCLB_IP}"

cat <<EOF > argocd-openapi.yaml
swagger: "2.0"
info:
  description: "Cloud Endpoints DNS"
  title: "Cloud Endpoints DNS"
  version: "1.0.0"
paths: {}
host: "argocd.endpoints.${PROJECT_ID}.cloud.goog"
x-google-endpoints:
- name: "argocd.endpoints.${PROJECT_ID}.cloud.goog"
  target: "${GCLB_IP}"
EOF
gcloud endpoints services deploy argocd-openapi.yaml --project ${PROJECT_ID}

cat <<EOF > ${script_dir}/../argo-cd-gke/overlays/gke_ingress/argocd-managed-cert.yaml
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata:
  name: argocd-managed-cert
  namespace: argocd
spec:
  domains:
  - "argocd.endpoints.${PROJECT_ID}.cloud.goog"
EOF

cat <<EOF > ${script_dir}/../argo-cd-gke/overlays/gke_ingress/argocd-server-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    kubernetes.io/ingress.global-static-ip-name: argocd-ip 
    networking.gke.io/v1beta1.FrontendConfig: argocd-frontend-config
    networking.gke.io/managed-certificates: argocd-managed-cert
spec:
  rules:
    - host: "argocd.endpoints.${PROJECT_ID}.cloud.goog"
      http:
        paths:
        - pathType: Prefix
          path: "/"
          backend:
            service:
              name: argocd-server
              port:
                number: 80
EOF

cat <<EOF > ${script_dir}/../argo-cd-gke/overlays/gke_ingress/argocd-sa.yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    iam.gke.io/gcp-service-account: argocd-fleet-admin@${PROJECT_ID}.iam.gserviceaccount.com
  name: argocd-application-controller
---
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    iam.gke.io/gcp-service-account: argocd-fleet-admin@${PROJECT_ID}.iam.gserviceaccount.com
  name: argocd-server
EOF

kubectl apply -k argo-cd-gke/overlays/gke_ingress
SECONDS=0

echo "Creating a global public IP for the ASM GW."
if [[ $(gcloud compute addresses describe asm-gw-ip --global --project ${PROJECT_ID}) ]]; then
  echo "ASM GW IP already exists."
else
  echo "Creating ASM GW IP."
  gcloud compute addresses create asm-gw-ip --global --project ${PROJECT_ID}
fi
export ASM_GW_IP=`gcloud compute addresses describe asm-gw-ip --global --format="value(address)"`
echo -e "GCLB_IP is ${ASM_GW_IP}"

echo "Creating gcp endpoints for each demo app."
cat <<EOF > rollout-demo-openapi.yaml
swagger: "2.0"
info:
  description: "Cloud Endpoints DNS"
  title: "Cloud Endpoints DNS"
  version: "1.0.0"
paths: {}
host: "rollout-demo.endpoints.${PROJECT_ID}.cloud.goog"
x-google-endpoints:
- name: "rollout-demo.endpoints.${PROJECT_ID}.cloud.goog"
  target: "${ASM_GW_IP}"
EOF

gcloud endpoints services deploy rollout-demo-openapi.yaml --project ${PROJECT_ID}

cat <<EOF > whereami-openapi.yaml
swagger: "2.0"
info:
  description: "Cloud Endpoints DNS"
  title: "Cloud Endpoints DNS"
  version: "1.0.0"
paths: {}
host: "whereami.endpoints.${PROJECT_ID}.cloud.goog"
x-google-endpoints:
- name: "whereami.endpoints.${PROJECT_ID}.cloud.goog"
  target: "${ASM_GW_IP}"
EOF

gcloud endpoints services deploy whereami-openapi.yaml --project ${PROJECT_ID}

### Setup Sync Repo w/ Argocd ###
echo "Waiting for managed cert to become Active, this can take about 5 mins."

while [[ $(kubectl get managedcertificates -n argocd argocd-managed-cert -o=jsonpath='{.status.certificateStatus}') != "Active" ]]; do
  sleep 10
  echo "Argocd managed certificate is not yet active and it has been $SECONDS seconds since it was created."
done

cat <<EOF > argo-cd-gke/overlays/gke_ingress/argocd-admin-project.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: admin
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  sourceRepos:
  - '*'
  destinations:
  - namespace: '*'
    server: '*'
  clusterResourceWhitelist:
  - group: '*'
    kind: '*'
EOF

kubectl apply -f argo-cd-gke/overlays/gke_ingress/argocd-admin-project.yaml -n argocd --context mccp-central-01

ARGOCD_SECRET=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo)
echo "Logging into to argocd."
argocd login "argocd.endpoints.${PROJECT_ID}.cloud.goog" --username admin --password ${ARGOCD_SECRET} --grpc-web

if [[ $(argocd cluster get mccp-central-01 --grpc-web) ]]; then
  echo "The mccp-central-01 cluster is already registered to ArgoCD."
else
  echo "Adding the mccp-central-01 cluster to ArgoCD."
  argocd cluster add mccp-central-01 --in-cluster --label=env="multi-cluster-controller" --grpc-web -y
fi

cd argo-repo-sync 
git init

REPO="https://github.com/"$(gh repo list | grep ${SYNC_REPO} | awk '{print $1}')

if [[ ${REPO} != "https://github.com/" ]]; then
  echo "${SYNC_REPO} repo already exists in github."
else
  echo "Creating repo ${SYNC_REPO} in github."
  gh repo create ${SYNC_REPO} --private --source=. --remote=upstream
  REPO="https://github.com/"$(gh repo list | grep ${SYNC_REPO} | awk '{print $1}')
fi

if [[ "$OSTYPE" == "darwin"* ]]; then
    find ./ -type f -exec sed -i '' -e "s/{{GKE_PROJECT_ID}}/${PROJECT_ID}/g" {} +
    find ./ -type f -exec sed -i '' -e "s/{{ASM_GW_IP}}/${ASM_GW_IP}/g" {} +
    find ./ -type f -exec sed -i '' -e "s|{{SYNC_REPO}}|${REPO}|g" {} +
else
    find ./ -type f -exec sed -i -e "s/{{GKE_PROJECT_ID}}/${PROJECT_ID}/g" {} +
    find ./ -type f -exec sed -i -e "s/{{ASM_GW_IP}}/${ASM_GW_IP}/g" {} +
    find ./ -type f -exec sed -i -e "s|{{SYNC_REPO}}|${REPO}|g" {} +
fi

git branch -M main
git add . && git commit -m "Initial commit"
git remote add origin ${REPO}
git push -u origin main

git checkout -b wave-one
git merge main
git add . && git commit -m "Setup wave-one branch."
git push -u origin wave-one 

git checkout -b wave-two
git merge wave-one
git add . && git commit -m "Setup wave-two branch."
git push -u origin wave-two
git checkout main

if [[ $(argocd repo get mccp-central-01 --grpc-web) ]]; then
  echo "${REPO} connection already exists."
else
  echo "Adding ${REPO} connection to ArgoCD."
  argocd repo add ${REPO} --username doesnotmatter --password ${PAT_TOKEN} --grpc-web
fi


### Setup applicationsets ###
kubectl apply -f generators/ -n argocd --context mccp-central-01

### Binding GCP RBAC to the ARGOCD service accounts
# gcloud projects add-iam-policy-binding ${PROJECT_ID} --role "roles/container.admin" --member "serviceAccount:${PROJECT_ID}.svc.id.goog[argocd/argocd-server]"
# gcloud projects add-iam-policy-binding ${PROJECT_ID} --role "roles/container.admin" --member "serviceAccount:${PROJECT_ID}.svc.id.goog[argocd/argocd-application-controller]"
# gcloud projects add-iam-policy-binding ${PROJECT_ID} --role "roles/gkehub.gatewayAdmin" --member "serviceAccount:${PROJECT_ID}.svc.id.goog[argocd/argocd-server]"
# gcloud projects add-iam-policy-binding ${PROJECT_ID} --role "roles/gkehub.gatewayAdmin" --member "serviceAccount:${PROJECT_ID}.svc.id.goog[argocd/argocd-application-controller]"
gcloud iam service-accounts create argocd-fleet-admin --project ${PROJECT_ID}
gcloud projects add-iam-policy-binding ${PROJECT_ID} --member "serviceAccount:argocd-fleet-admin@${PROJECT_ID}.iam.gserviceaccount.com" --role 'roles/container.admin' --project ${PROJECT_ID}
gcloud projects add-iam-policy-binding ${PROJECT_ID} --member "serviceAccount:argocd-fleet-admin@${PROJECT_ID}.iam.gserviceaccount.com" --role 'roles/gkehub.gatewayAdmin' --project ${PROJECT_ID}
gcloud iam service-accounts add-iam-policy-binding --role roles/iam.workloadIdentityUser --member "serviceAccount:${PROJECT_ID}.svc.id.goog[argocd/argocd-server]" argocd-fleet-admin@${PROJECT_ID}.iam.gserviceaccount.com --project ${PROJECT_ID}
gcloud iam service-accounts add-iam-policy-binding --role roles/iam.workloadIdentityUser --member "serviceAccount:${PROJECT_ID}.svc.id.goog[argocd/argocd-application-controller]" argocd-fleet-admin@${PROJECT_ID}.iam.gserviceaccount.com --project ${PROJECT_ID}

echo "The Fleet has been configured, checkout the sync status here:"
echo "https://argocd.endpoints.${PROJECT_ID}.cloud.goog"
