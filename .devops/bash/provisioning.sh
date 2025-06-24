#!/usr/bin/env bash
set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Error handler
error_trap() {
    log_error "An error occurred on line $1. Exiting."
    exit 1
}
trap 'error_trap $LINENO' ERR

print_usage() {
    echo "Usage: $0 --environment ENV --location LOCATION --resource-group RG --node-count COUNT --subscription SUB --vm-size VM_SIZE --deploy-env ENV"
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --environment) env="$2"; shift 2 ;;
        --location) MY_LOCATION="$2"; shift 2 ;;
        --node-count) NODE_COUNT="$2"; shift 2 ;;
        --subscription) AZ_SUBSCRIPTION="$2"; shift 2 ;;
        --vm-size) VM_SIZE="$2"; shift 2 ;;
        --deploy-env) DEPLOY_ENV="$2"; shift 2 ;;
        *) log_error "Unknown argument: $1"; print_usage ;;
    esac
done



# Validate required arguments
if [[ -z "${env:-}" || -z "${MY_LOCATION:-}" || -z "${NODE_COUNT:-}" || -z "${AZ_SUBSCRIPTION:-}" || -z "${VM_SIZE:-}" || -z "${DEPLOY_ENV:-}" ]]; then
    log_error "Missing required arguments."
    print_usage
fi

log_info "Setting Azure subscription to '$AZ_SUBSCRIPTION'"
az account set --subscription "$AZ_SUBSCRIPTION"

export MY_IDENTITY_NAME="airflow-identity-${env}"
export MY_ACR_REGISTRY=airflowregistry${env}${env}
export MY_KEYVAULT_NAME="airflow-vault-${env}-kv"
export MY_CLUSTER_NAME="apache-airflow-aks"
export SERVICE_ACCOUNT_NAME="airflow"
export SERVICE_ACCOUNT_NAMESPACE="airflow"
export AKS_AIRFLOW_NAMESPACE="airflow"
export AKS_AIRFLOW_CLUSTER_NAME="cluster-aks-airflow"
export AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME="airflowsasa${env}"
export AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME="airflow-logs"
export AKS_AIRFLOW_LOGS_STORAGE_SECRET_NAME="storage-account-credentials"
export MY_RESOURCE_GROUP_NAME=apache-airflow-${env}

# Provision resource group
provision_resource_group() {
    log_info  "Provisioning resource group..."
    if [[ "${DEPLOY_ENV}" == "azure" ]]; then
        if az group show --name "$MY_RESOURCE_GROUP_NAME" &>/dev/null; then
            log_warning "Resource group '$MY_RESOURCE_GROUP_NAME' already exists. Skipping it..."
        else
            log_info "Creating resource group '$MY_RESOURCE_GROUP_NAME' in '$MY_LOCATION'"
            az group create --name "$MY_RESOURCE_GROUP_NAME" --location "$MY_LOCATION" --output table
            log_success "Resource group created."
        fi
    else
        log_error "Provider '${DEPLOY_ENV}' is invalid or unavailable. Skipping resource group provisioning."
    fi
}

# Provision managed identity
provision_identity() {
    log_info  "Provisioning identity on deploy provider..."
    if [[ "${DEPLOY_ENV}" == "azure" ]]; then
        if az identity show --name "$MY_IDENTITY_NAME" --resource-group "$MY_RESOURCE_GROUP_NAME" &>/dev/null; then
            log_warning "Identity '$MY_IDENTITY_NAME' already exists. Skipping it..."
        else
            log_info "Creating identity '$MY_IDENTITY_NAME'"
            az identity create --name "$MY_IDENTITY_NAME" --resource-group "$MY_RESOURCE_GROUP_NAME" --output table
            log_success "Identity created."
        fi
        export MY_IDENTITY_NAME_ID=$(az identity show --name "$MY_IDENTITY_NAME" --resource-group "$MY_RESOURCE_GROUP_NAME" --query id --output tsv)
        export MY_IDENTITY_NAME_PRINCIPAL_ID=$(az identity show --name "$MY_IDENTITY_NAME" --resource-group "$MY_RESOURCE_GROUP_NAME" --query principalId --output tsv)
        export MY_IDENTITY_NAME_CLIENT_ID=$(az identity show --name "$MY_IDENTITY_NAME" --resource-group "$MY_RESOURCE_GROUP_NAME" --query clientId --output tsv)
    else
        log_error "Provider '${DEPLOY_ENV}' is invalid or unavailable. Skipping identity provisioning."
    fi
}

# Provision Key Vault
provision_secret_store() {
  log_info  "Provisioning secret store..."
    if [[ "${DEPLOY_ENV}" == "azure" ]]; then
        if az keyvault show --name "$MY_KEYVAULT_NAME" &>/dev/null; then
            log_warning "KeyVault '$MY_KEYVAULT_NAME' already exists. Skipping it..."
        else
            log_info "Creating KeyVault '$MY_KEYVAULT_NAME'"
            az keyvault create --name "$MY_KEYVAULT_NAME" --resource-group "$MY_RESOURCE_GROUP_NAME" --location "$MY_LOCATION" --enable-rbac-authorization false --output table
            log_success "KeyVault created."
        fi
        export KEYVAULTID=$(az keyvault show --name "$MY_KEYVAULT_NAME" --query id --output tsv)
        export KEYVAULTURL=$(az keyvault show --name "$MY_KEYVAULT_NAME" --query properties.vaultUri --output tsv)
    else
        log_error "Provider '${DEPLOY_ENV}' is invalid or unavailable. Skipping KeyVault provisioning."
    fi
}


provision_container_registry() {
    log_info "Provisioning container registry..."
    if [[ "${DEPLOY_ENV}" == "azure" ]]; then
        local name_status
        name_status=$(az acr check-name --name "$MY_ACR_REGISTRY" --query nameAvailable --output tsv)
        if [[ "$name_status" == "true" ]]; then
            log_info "Creating Azure Container Registry '$MY_ACR_REGISTRY'"
            az acr create --name "$MY_ACR_REGISTRY" --resource-group "$MY_RESOURCE_GROUP_NAME" --sku Premium --location "$MY_LOCATION" --admin-enabled true --output table
            log_success "ACR created."
        else
            # Check if registry exists in *ANY* resource group in current subscription
            local acr_rg
            acr_rg=$(az acr list --query "[?name=='$MY_ACR_REGISTRY'].resourceGroup" --output tsv)
            if [[ -n "$acr_rg" ]]; then
                if [[ "$acr_rg" == "$MY_RESOURCE_GROUP_NAME" ]]; then
                    log_warning "ACR '$MY_ACR_REGISTRY' already exists in resource group '$MY_RESOURCE_GROUP_NAME'. Skipping it..."
                else
                    log_error "ACR name '$MY_ACR_REGISTRY' is in use in resource group '$acr_rg'. Please use that resource group, or choose a new name."
                    return 1
                fi
            else
                log_error "ACR name '$MY_ACR_REGISTRY' is not available, but is not found in this subscription. It may be soft deleted (recently deleted and not yet released by Azure). Wait up to 1 hour, or choose a new name."
                return 1
            fi
        fi
        export MY_ACR_REGISTRY_ID=$(az acr show --name "$MY_ACR_REGISTRY" --resource-group "$MY_RESOURCE_GROUP_NAME" --query id --output tsv 2>/dev/null || echo "")
    else
        log_error "Provider '${DEPLOY_ENV}' is invalid or unavailable. Skipping ACR provisioning."
    fi
}


provision_storage() {
    if [[ "${DEPLOY_ENV}" == "azure" ]]; then
        # Check if the storage account name is available (globally unique in Azure)
        local name_available
        name_available=$(az storage account check-name --name "$AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME" --query 'nameAvailable' -o tsv)

        if [[ "$name_available" == "false" ]]; then
            # The storage account exists somewhere in the subscription or globally
            log_warning "Storage account '$AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME' already exists. Skipping it..."
        else
            log_info "Creating storage account '$AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME'"
            az storage account create --name "$AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME" --resource-group "$MY_RESOURCE_GROUP_NAME" --location "$MY_LOCATION" --sku Standard_ZRS --output table
            log_success "Storage account created."
        fi

        # Find the resource group of the existing storage account (if exists)
        if [[ "$name_available" == "false" ]]; then
            # Try to get the resource group where the storage account exists
            EXISTING_RG=$(az storage account list --query "[?name=='$AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME'].resourceGroup" -o tsv)
        else
            EXISTING_RG="$MY_RESOURCE_GROUP_NAME"
        fi

        # Get the storage account key from the correct resource group
        export AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_KEY=$(az storage account keys list --account-name "$AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME" --resource-group "$EXISTING_RG" --query "[0].value" -o tsv)

        # Container check/create
        if az storage container show --name "$AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME" --account-name "$AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME" --account-key "$AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_KEY" &>/dev/null; then
            log_warning "Storage container '$AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME' already exists. Skipping it..."
        else
            log_info "Creating storage container '$AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME'"
            az storage container create --name "$AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME" --account-name "$AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME" --account-key "$AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_KEY" --output table
            log_success "Storage container created."
        fi

        log_info "Storing storage account credentials in KeyVault."
        az keyvault secret set --vault-name "$MY_KEYVAULT_NAME" --name AKS-AIRFLOW-LOGS-STORAGE-ACCOUNT-NAME --value "$AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME"
        az keyvault secret set --vault-name "$MY_KEYVAULT_NAME" --name AKS-AIRFLOW-LOGS-STORAGE-ACCOUNT-KEY --value "$AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_KEY"
    else
        log_error "Provider '${DEPLOY_ENV}' is invalid or unavailable. Skipping storage provisioning."
    fi
}

provision_cluster() {
    if [[ "${DEPLOY_ENV}" == "azure" ]]; then
        if az aks show --name "$MY_CLUSTER_NAME" --resource-group "$MY_RESOURCE_GROUP_NAME" &>/dev/null; then
            log_warning "AKS cluster '$MY_CLUSTER_NAME' already exists. Skipping it..."
        else
            log_info "Creating AKS cluster '$MY_CLUSTER_NAME'"
            az aks create --location "$MY_LOCATION" --name "$MY_CLUSTER_NAME" --tier standard --resource-group "$MY_RESOURCE_GROUP_NAME" \
                --network-plugin azure \
                --node-vm-size "$VM_SIZE" \
                --node-count "$NODE_COUNT" \
                --auto-upgrade-channel stable \
                --node-os-upgrade-channel NodeImage \
                --attach-acr "$MY_ACR_REGISTRY" --enable-oidc-issuer \
                --enable-blob-driver --enable-workload-identity \
                --generate-ssh-keys \
                --output table
            log_success "AKS cluster created."
        fi

        export OIDC_URL=$(az aks show --resource-group "$MY_RESOURCE_GROUP_NAME" --name "$MY_CLUSTER_NAME" --query oidcIssuerProfile.issuerUrl --output tsv)
        export KUBELET_IDENTITY=$(az aks show -g "$MY_RESOURCE_GROUP_NAME" --name "$MY_CLUSTER_NAME" --output tsv --query identityProfile.kubeletidentity.objectId)
        az role assignment create --assignee "$KUBELET_IDENTITY" --role "AcrPull" --scope "$MY_ACR_REGISTRY_ID" --output table || log_warning "Failed to assign AcrPull. It may already be assigned."
        az aks get-credentials --resource-group "$MY_RESOURCE_GROUP_NAME" --name "$MY_CLUSTER_NAME" --overwrite-existing --output table
    else
        log_error "Provider '${DEPLOY_ENV}' is invalid or unavailable. Skipping AKS provisioning."
    fi
}


import_images() {
    if [[ "${DEPLOY_ENV}" == "azure" ]]; then
        local images=(
            "docker.io/apache/airflow:airflow-pgbouncer-2024.01.19-1.21.0 airflow:airflow-pgbouncer-2024.01.19-1.21.0"
            "docker.io/apache/airflow:airflow-pgbouncer-exporter-2024.06.18-0.17.0 airflow:airflow-pgbouncer-exporter-2024.06.18-0.17.0"
            "docker.io/bitnami/postgresql:16.1.0-debian-11-r15 postgresql:16.1.0-debian-11-r15"
            "quay.io/prometheus/statsd-exporter:v0.26.1 statsd-exporter:v0.26.1"
            "docker.io/apache/airflow:2.9.3 airflow:2.9.3"
            "registry.k8s.io/git-sync/git-sync:v4.1.0 git-sync:v4.1.0"
        )
        for img in "${images[@]}"; do
            local src="${img%% *}"
            local dest="${img##* }"
            log_info "Importing image '$src' as '$dest' into ACR '$MY_ACR_REGISTRY'"
            if az acr repository show --name "$MY_ACR_REGISTRY" --repository "${dest%%:*}" &>/dev/null; then
                log_warning "Image '$dest' already exists in ACR."
            else
                az acr import --name "$MY_ACR_REGISTRY" --source "$src" --image "$dest"
                log_success "Imported image '$dest'"
            fi
        done
    else
        log_error "Provider '${DEPLOY_ENV}' is invalid or unavailable. Skipping image import."
    fi
}

# MAIN EXECUTION
provision_resource_group
provision_identity
provision_secret_store
provision_container_registry
provision_storage
provision_cluster
import_images

log_success "Provisioning script completed successfully."