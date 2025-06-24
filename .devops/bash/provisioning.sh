#helm repo add apache-airflow https://airflow.apache.org
#helm install airflow apache-airflow/airflow -n airflow -f helm/values.yaml --debug
#kubectl port-forward svc/airflow-webserver 8080:8080 -n airflow


export env="dev"
export MY_LOCATION=canadacentral
export MY_RESOURCE_GROUP_NAME=apache-airflow-${env}
export MY_IDENTITY_NAME=airflow-identity-${env}
export MY_ACR_REGISTRY=airflowregistrydev${env}
export MY_KEYVAULT_NAME=airflow-vault-$(echo $env)-kv
export MY_CLUSTER_NAME=apache-airflow-aks
export SERVICE_ACCOUNT_NAME=airflow
export SERVICE_ACCOUNT_NAMESPACE=airflow
export AKS_AIRFLOW_NAMESPACE=airflow
export AKS_AIRFLOW_CLUSTER_NAME=cluster-aks-airflow
export AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME=airflowsasa$(echo $env)
export AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME=airflow-logs
export AKS_AIRFLOW_LOGS_STORAGE_SECRET_NAME=storage-account-credentials
#storage-account-credentials


az group create --name $MY_RESOURCE_GROUP_NAME --location $MY_LOCATION --output table
az identity create --name $MY_IDENTITY_NAME --resource-group $MY_RESOURCE_GROUP_NAME --output table
export MY_IDENTITY_NAME_ID=$(az identity show --name $MY_IDENTITY_NAME --resource-group $MY_RESOURCE_GROUP_NAME --query id --output tsv)
export MY_IDENTITY_NAME_PRINCIPAL_ID=$(az identity show --name $MY_IDENTITY_NAME --resource-group $MY_RESOURCE_GROUP_NAME --query principalId --output tsv)
export MY_IDENTITY_NAME_CLIENT_ID=$(az identity show --name $MY_IDENTITY_NAME --resource-group $MY_RESOURCE_GROUP_NAME --query clientId --output tsv)

az keyvault create --name $MY_KEYVAULT_NAME --resource-group $MY_RESOURCE_GROUP_NAME --location $MY_LOCATION --enable-rbac-authorization false --output table
export KEYVAULTID=$(az keyvault show --name $MY_KEYVAULT_NAME --query "id" --output tsv)
export KEYVAULTURL=$(az keyvault show --name $MY_KEYVAULT_NAME --query "properties.vaultUri" --output tsv)


az acr create --name ${MY_ACR_REGISTRY} --resource-group $MY_RESOURCE_GROUP_NAME --sku Premium --location $MY_LOCATION --admin-enabled true --output table
export MY_ACR_REGISTRY_ID=$(az acr show --name $MY_ACR_REGISTRY --resource-group $MY_RESOURCE_GROUP_NAME --query id --output tsv)

az storage account create --name $AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME --resource-group $MY_RESOURCE_GROUP_NAME --location $MY_LOCATION --sku Standard_ZRS --output table
export AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_KEY=$(az storage account keys list --account-name $AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME --query "[0].value" -o tsv)
az storage container create --name $AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME --account-name $AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME --output table --account-key $AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_KEY
az keyvault secret set --vault-name $MY_KEYVAULT_NAME --name AKS-AIRFLOW-LOGS-STORAGE-ACCOUNT-NAME --value $AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME
az keyvault secret set --vault-name $MY_KEYVAULT_NAME --name AKS-AIRFLOW-LOGS-STORAGE-ACCOUNT-KEY --value $AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_KEY


az aks create --location $MY_LOCATION --name $MY_CLUSTER_NAME --tier standard --resource-group $MY_RESOURCE_GROUP_NAME \
--network-plugin azure\
 --node-vm-size Standard_B2ps_v2 \
 --node-count 2 \
 --auto-upgrade-channel stable \
 --node-os-upgrade-channel NodeImage \
 --attach-acr ${MY_ACR_REGISTRY} --enable-oidc-issuer \
 --enable-blob-driver --enable-workload-identity  \
 --generate-ssh-keys \
 --output table


export OIDC_URL=$(az aks show --resource-group $MY_RESOURCE_GROUP_NAME --name $MY_CLUSTER_NAME --query oidcIssuerProfile.issuerUrl --output tsv)

export KUBELET_IDENTITY=$(az aks show -g $MY_RESOURCE_GROUP_NAME --name $MY_CLUSTER_NAME --output tsv --query identityProfile.kubeletidentity.objectId)
az role assignment create --assignee ${KUBELET_IDENTITY} --role "AcrPull" --scope ${MY_ACR_REGISTRY_ID} --output table
az aks get-credentials --resource-group $MY_RESOURCE_GROUP_NAME --name $MY_CLUSTER_NAME --overwrite-existing --output table


az acr import --name $MY_ACR_REGISTRY --source docker.io/apache/airflow:airflow-pgbouncer-2024.01.19-1.21.0 --image airflow:airflow-pgbouncer-2024.01.19-1.21.0
az acr import --name $MY_ACR_REGISTRY --source docker.io/apache/airflow:airflow-pgbouncer-exporter-2024.06.18-0.17.0 --image airflow:airflow-pgbouncer-exporter-2024.06.18-0.17.0
az acr import --name $MY_ACR_REGISTRY --source docker.io/bitnami/postgresql:16.1.0-debian-11-r15 --image postgresql:16.1.0-debian-11-r15
az acr import --name $MY_ACR_REGISTRY --source quay.io/prometheus/statsd-exporter:v0.26.1 --image statsd-exporter:v0.26.1
az acr import --name $MY_ACR_REGISTRY --source docker.io/apache/airflow:2.9.3 --image airflow:2.9.3
az acr import --name $MY_ACR_REGISTRY --source registry.k8s.io/git-sync/git-sync:v4.1.0 --image git-sync:v4.1.0