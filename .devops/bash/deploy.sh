#!/bin/bash

kubectl create namespace ${AKS_AIRFLOW_NAMESPACE} --dry-run=client --output yaml | kubectl apply -f -

export APP_OBJ_ID=$(az ad sp list --all --query "[].{objectId:id}" -o table | grep f0a7d5cd-717a-45bd-8246-0b9d3bb7f802)
# giver permission to key vault
az keyvault set-policy --name $MY_KEYVAULT_NAME --object-id $MY_IDENTITY_NAME_PRINCIPAL_ID --secret-permissions get --output table
az keyvault set-policy \
  --name "$MY_KEYVAULT_NAME" \
  --object-id "${APP_OBJ_ID}" \
  --secret-permissions get


export TENANT_ID=$(az account show --query tenantId -o tsv)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: "${MY_IDENTITY_NAME_CLIENT_ID}"
    azure.workload.identity/tenant-id: "${TENANT_ID}"
  name: "${SERVICE_ACCOUNT_NAME}"
  namespace: "${AKS_AIRFLOW_NAMESPACE}"
EOF

helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets \
external-secrets/external-secrets \
--namespace ${AKS_AIRFLOW_NAMESPACE} \
--create-namespace \
--set installCRDs=true \
--wait

kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: azure-store
  namespace: ${AKS_AIRFLOW_NAMESPACE}
spec:
  provider:
    # provider type: azure keyvault
    azurekv:
      authType: WorkloadIdentity
      vaultUrl: "${KEYVAULTURL}"
      serviceAccountRef:
        name: ${SERVICE_ACCOUNT_NAME}
EOF

kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: airflow-aks-azure-logs-secrets
  namespace: ${AKS_AIRFLOW_NAMESPACE}
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: SecretStore
    name: azure-store

  target:
    name: ${AKS_AIRFLOW_LOGS_STORAGE_SECRET_NAME}
    creationPolicy: Owner

  data:
    # name of the SECRET in the Azure KV (no prefix is by default a SECRET)
    - secretKey: azurestorageaccountname
      remoteRef:
        key: AKS-AIRFLOW-LOGS-STORAGE-ACCOUNT-NAME
    - secretKey: azurestorageaccountkey
      remoteRef:
        key: AKS-AIRFLOW-LOGS-STORAGE-ACCOUNT-KEY
EOF

echo "identity client id: ${MY_IDENTITY_NAME}/${MY_RESOURCE_GROUP_NAME}/${AKS_AIRFLOW_NAMESPACE}/${SERVICE_ACCOUNT_NAME}"
az identity federated-credential create \
  --name external-secret-operator \
  --identity-name "${MY_IDENTITY_NAME}" \
  --resource-group "${MY_RESOURCE_GROUP_NAME}" \
  --issuer "${OIDC_URL}" \
  --subject "system:serviceaccount:${AKS_AIRFLOW_NAMESPACE}:${SERVICE_ACCOUNT_NAME}" \
  --audience "api://AzureADTokenExchange" \
  --output table

kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-airflow-logs
  labels:
    type: local
spec:
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Delete
  storageClassName: azureblob-fuse-premium
  mountOptions:
    - -o allow_other
    - --file-cache-timeout-in-seconds=120
  csi:
    driver: blob.csi.azure.com
    readOnly: false
    volumeHandle: airflow-logs-1
    volumeAttributes:
      resourceGroup: ${MY_RESOURCE_GROUP_NAME}
      storageAccount: ${AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME}
      containerName: ${AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME}
    nodeStageSecretRef:
      name: ${AKS_AIRFLOW_LOGS_STORAGE_SECRET_NAME}
      namespace: ${AKS_AIRFLOW_NAMESPACE}
EOF

kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-airflow-logs
  namespace: ${AKS_AIRFLOW_NAMESPACE}
spec:
  storageClassName: azureblob-fuse-premium
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  volumeName: pv-airflow-logs
EOF

kubectl create secret generic airflow-git-ssh-secret \
  --from-file=gitSshKey=$HOME/.ssh/airflowsshkey.pub \
  --namespace ${AKS_AIRFLOW_NAMESPACE}

cat <<EOF > airflow_values.yaml
webserverSecretKey: f1023ed56bd3eb8ee2b069c5eec748b5
images:
  airflow:
    repository: $MY_ACR_REGISTRY.azurecr.io/airflow
    tag: 2.9.3
    # Specifying digest takes precedence over tag.
    digest: ~
    pullPolicy: IfNotPresent
  # To avoid images with user code, you can turn this to 'true' and
  # all the 'run-airflow-migrations' and 'wait-for-airflow-migrations' containers/jobs
  # will use the images from 'defaultAirflowRepository:defaultAirflowTag' values
  # to run and wait for DB migrations .
  useDefaultImageForMigration: false
  # timeout (in seconds) for airflow-migrations to complete
  migrationsWaitTimeout: 60
  pod_template:
    # Note that \`images.pod_template.repository\` and \`images.pod_template.tag\` parameters
    # can be overridden in \`config.kubernetes\` section. So for these parameters to have effect
    # \`config.kubernetes.worker_container_repository\` and \`config.kubernetes.worker_container_tag\`
    # must be not set .
    repository: $MY_ACR_REGISTRY.azurecr.io/airflow
    tag: 2.9.3
    pullPolicy: IfNotPresent
  flower:
    repository: $MY_ACR_REGISTRY.azurecr.io/airflow
    tag: 2.9.3
    pullPolicy: IfNotPresent
  statsd:
    repository: $MY_ACR_REGISTRY.azurecr.io/statsd-exporter
    tag: v0.26.1
    pullPolicy: IfNotPresent
  pgbouncer:
    repository: $MY_ACR_REGISTRY.azurecr.io/airflow
    tag: airflow-pgbouncer-2024.01.19-1.21.0
    pullPolicy: IfNotPresent
  pgbouncerExporter:
    repository: $MY_ACR_REGISTRY.azurecr.io/airflow
    tag: airflow-pgbouncer-exporter-2024.06.18-0.17.0
    pullPolicy: IfNotPresent
  gitSync:
    repository: $MY_ACR_REGISTRY.azurecr.io/git-sync
    tag: v4.1.0
    pullPolicy: IfNotPresent

# Airflow executor
executor: "KubernetesExecutor"

# Environment variables for all airflow containers
env:
  - name: ENVIRONMENT
    value: dev

extraEnv: |
  - name: AIRFLOW__CORE__DEFAULT_TIMEZONE
    value: 'America/New_York'

# Configuration for postgresql subchart
# Not recommended for production! Instead, spin up your own Postgresql server and use the \`data\` attribute in this
# yaml file.
postgresql:
  enabled: true

# Enable pgbouncer. See https://airflow.apache.org/docs/helm-chart/stable/production-guide.html#pgbouncer
pgbouncer:
  enabled: true

dags:
  gitSync:
    enabled: true
    repo: https://github.com/donhighmsft/airflowexamples.git
    branch: main
    rev: HEAD
    depth: 1
    maxFailures: 0
    subPath: "dags"
    sshKeySecret: airflow-git-ssh-secret
    knownHosts: |
      github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=

logs:
  persistence:
    enabled: true
    existingClaim: pvc-airflow-logs
    storageClassName: azureblob-fuse-premium

# We disable the log groomer sidecar because we use Azure Blob Storage for logs, with lifecyle policy set.
triggerer:
  logGroomerSidecar:
    enabled: false

scheduler:
  logGroomerSidecar:
    enabled: false

workers:
  logGroomerSidecar:
    enabled: false
EOF

helm repo add apache-airflow https://airflow.apache.org
helm repo update
helm search repo airflow

helm install airflow apache-airflow/airflow --namespace ${AKS_AIRFLOW_NAMESPACE} --create-namespace -f airflow_values.yaml  --version 1.15.0 --debug

helm search repo airflow

kubectl get pods -n ${AKS_AIRFLOW_NAMESPACE}

kubectl port-forward svc/airflow-webserver 9090:8080 -n ${AKS_AIRFLOW_NAMESPACE}