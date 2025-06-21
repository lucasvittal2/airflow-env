#!/bin/bash

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Help function
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    -e, --environment     Environment name (required: dev, staging, prod)
    -l, --location        Azure location (default: canadacentral)
    -r, --resource-group  Resource group name (optional, will use default pattern)
    -s, --subscription    Azure subscription ID (optional)
    -n, --node-count      AKS node count (default: 3)
    -v, --vm-size         AKS node VM size (default: Standard_DS4_v2)
    --dry-run            Show what would be created without actually creating
    -h, --help           Show this help message

Environment Variables (alternative to command line args):
    ENVIRONMENT          Environment name
    AZURE_LOCATION       Azure location
    RESOURCE_GROUP_NAME  Resource group name
    AZURE_SUBSCRIPTION   Azure subscription ID
    AKS_NODE_COUNT       AKS node count
    AKS_VM_SIZE          AKS node VM size

Examples:
    $0 -e dev -l eastus
    $0 --environment prod --location westeurope --node-count 5
    ENVIRONMENT=staging $0
EOF
}

# Default values
DEFAULT_LOCATION="canadacentral"
DEFAULT_NODE_COUNT=3
DEFAULT_VM_SIZE="Standard_DS4_v2"
DRY_RUN=false

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -e|--environment)
                ENVIRONMENT="$2"
                shift 2
                ;;
            -l|--location)
                AZURE_LOCATION="$2"
                shift 2
                ;;
            -r|--resource-group)
                RESOURCE_GROUP_NAME="$2"
                shift 2
                ;;
            -s|--subscription)
                AZURE_SUBSCRIPTION="$2"
                shift 2
                ;;
            -n|--node-count)
                AKS_NODE_COUNT="$2"
                shift 2
                ;;
            -v|--vm-size)
                AKS_VM_SIZE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Validate environment
validate_environment() {
    if [[ -z "${ENVIRONMENT:-}" ]]; then
        log_error "Environment is required. Use -e/--environment or set ENVIRONMENT variable."
        exit 1
    fi

    case "${ENVIRONMENT}" in
        dev|staging|prod)
            log_info "Environment: ${ENVIRONMENT}"
            ;;
        *)
            log_error "Invalid environment: ${ENVIRONMENT}. Must be dev, staging, or prod."
            exit 1
            ;;
    esac
}

# Set default values and validate inputs
setup_variables() {
    # Set defaults from environment variables or command line args
    ENVIRONMENT="${ENVIRONMENT:-}"
    AZURE_LOCATION="${AZURE_LOCATION:-$DEFAULT_LOCATION}"
    AKS_NODE_COUNT="${AKS_NODE_COUNT:-$DEFAULT_NODE_COUNT}"
    AKS_VM_SIZE="${AKS_VM_SIZE:-$DEFAULT_VM_SIZE}"

    # Generate resource names based on environment
    RESOURCE_GROUP_NAME="${RESOURCE_GROUP_NAME:-apache-airflow-${ENVIRONMENT}}"
    IDENTITY_NAME="airflow-identity-${ENVIRONMENT}"
    ACR_REGISTRY="airflowregistry${ENVIRONMENT}"
    KEYVAULT_NAME="airflow-vault-${ENVIRONMENT}-kv"
    CLUSTER_NAME="apache-airflow-aks-${ENVIRONMENT}"
    STORAGE_ACCOUNT_NAME="airflowlogs${ENVIRONMENT}sa"

    # Fixed naming conventions
    SERVICE_ACCOUNT_NAME="airflow"
    SERVICE_ACCOUNT_NAMESPACE="airflow"
    AKS_AIRFLOW_NAMESPACE="airflow"
    AKS_AIRFLOW_CLUSTER_NAME="cluster-aks-airflow"
    AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME="airflow-logs"
    AKS_AIRFLOW_LOGS_STORAGE_SECRET_NAME="storage-account-credentials"

    log_info "Configuration:"
    log_info "  Environment: ${ENVIRONMENT}"
    log_info "  Location: ${AZURE_LOCATION}"
    log_info "  Resource Group: ${RESOURCE_GROUP_NAME}"
    log_info "  AKS Node Count: ${AKS_NODE_COUNT}"
    log_info "  AKS VM Size: ${AKS_VM_SIZE}"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if Azure CLI is installed
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI is not installed or not in PATH"
        exit 1
    fi

    # Check if kubectl is installed
    if ! command -v kubectl &> /dev/null; then
        log_warning "kubectl is not installed. You won't be able to connect to the cluster."
    fi

    # Check Azure CLI login status
    if ! az account show &> /dev/null; then
        log_error "Not logged into Azure CLI. Please run 'az login' first."
        exit 1
    fi

    # Set subscription if provided
    if [[ -n "${AZURE_SUBSCRIPTION:-}" ]]; then
        log_info "Setting Azure subscription to: ${AZURE_SUBSCRIPTION}"
        az account set --subscription "${AZURE_SUBSCRIPTION}"
    fi

    log_success "Prerequisites check completed"
}

# Execute command with dry-run support
execute_command() {
    local description="$1"
    shift

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] ${description}"
        log_info "[DRY-RUN] Command: $*"
        return 0
    fi

    log_info "${description}"
    if ! "$@"; then
        log_error "Failed: ${description}"
        return 1
    fi

    return 0
}

# Create resource group
create_resource_group() {
    execute_command "Creating resource group: ${RESOURCE_GROUP_NAME}" \
        az group create \
        --name "${RESOURCE_GROUP_NAME}" \
        --location "${AZURE_LOCATION}" \
        --output table

    log_success "Resource group created successfully"
}

# Create managed identity
create_managed_identity() {
    execute_command "Creating user assigned managed identity: ${IDENTITY_NAME}" \
        az identity create \
        --name "${IDENTITY_NAME}" \
        --resource-group "${RESOURCE_GROUP_NAME}" \
        --output table

    if [[ "$DRY_RUN" != "true" ]]; then
        # Export identity information
        export IDENTITY_ID=$(az identity show --name "${IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" --query id --output tsv)
        export IDENTITY_PRINCIPAL_ID=$(az identity show --name "${IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" --query principalId --output tsv)
        export IDENTITY_CLIENT_ID=$(az identity show --name "${IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" --query clientId --output tsv)
    fi

    log_success "Managed identity created successfully"
}

# Create Key Vault

create_key_vault() {
    # Check if Key Vault already exists
    log_info "Checking if Key Vault '${KEYVAULT_NAME}' exists..."

    if [[ "$DRY_RUN" != "true" ]]; then
        local vault_exists=$(az keyvault show --name "${KEYVAULT_NAME}" --query "name" --output tsv 2>/dev/null || echo "")

        if [[ -n "$vault_exists" ]]; then
            log_warning "Key Vault '${KEYVAULT_NAME}' already exists, skipping creation"

            # Still export the variables for existing vault
            export KEYVAULT_ID=$(az keyvault show --name "${KEYVAULT_NAME}" --query "id" --output tsv)
            export KEYVAULT_URL=$(az keyvault show --name "${KEYVAULT_NAME}" --query "properties.vaultUri" --output tsv)

            log_success "Key Vault variables set for existing vault"
            return 0
        fi
    else
        log_info "DRY_RUN mode: Would check for existing Key Vault '${KEYVAULT_NAME}'"
    fi

    # Create Key Vault if it doesn't exist
    execute_command "Creating Azure Key Vault: ${KEYVAULT_NAME}" \
        az keyvault create \
        --name "${KEYVAULT_NAME}" \
        --resource-group "${RESOURCE_GROUP_NAME}" \
        --location "${AZURE_LOCATION}" \
        --enable-rbac-authorization false \
        --output table

    if [[ "$DRY_RUN" != "true" ]]; then
        export KEYVAULT_ID=$(az keyvault show --name "${KEYVAULT_NAME}" --query "id" --output tsv)
        export KEYVAULT_URL=$(az keyvault show --name "${KEYVAULT_NAME}" --query "properties.vaultUri" --output tsv)
    fi

    log_success "Key Vault created successfully"
}

# Create Container Registry
create_container_registry() {

    REGISTRATION_STATE=$(az provider show --namespace Microsoft.ContainerRegistry --query "registrationState")
    log_info "Checking if subscription is registered to use container registry..."
    if [ "$REGISTRATION_STATE" = "NotRegistered" ]; then
      log_warning "the Microsoft.ContainerRegistry state is 'NotRegistered'. Registering it now..."
      az provider register --namespace Microsoft.ContainerRegistry
      log_info "Subscription registered to use Azure container service."
    else
        echo "The provider Microsoft.ContainerRegistry already is registered."
    fi



    log_info "Checking if Container Registry '${ACR_REGISTRY}' exists..."
    az provider register --namespace Microsoft.ContainerRegistry
    if [[ "$DRY_RUN" != "true" ]]; then
        local registry_exists=$(az acr show --name "${ACR_REGISTRY}" --resource-group "${RESOURCE_GROUP_NAME}" --query "name" --output tsv 2>/dev/null || echo "")

        if [[ -n "$registry_exists" ]]; then
            log_warning "Container Registry '${ACR_REGISTRY}' already exists, skipping creation"

            # Still export the variables for existing registry
            export ACR_REGISTRY_ID=$(az acr show --name "${ACR_REGISTRY}" --resource-group "${RESOURCE_GROUP_NAME}" --query id --output tsv)

            log_success "Container Registry variables set for existing registry"
            return 0
        fi
    else
        log_info "DRY_RUN mode: Would check for existing Container Registry '${ACR_REGISTRY}'"
    fi

    # Create Container Registry if it doesn't exist
    execute_command "Creating Azure Container Registry: ${ACR_REGISTRY}" \
        az acr create \
        --name "${ACR_REGISTRY}" \
        --resource-group "${RESOURCE_GROUP_NAME}" \
        --sku Premium \
        --location "${AZURE_LOCATION}" \
        --admin-enabled true \
        --output table

    if [[ "$DRY_RUN" != "true" ]]; then
        export ACR_REGISTRY_ID=$(az acr show --name "${ACR_REGISTRY}" --resource-group "${RESOURCE_GROUP_NAME}" --query id --output tsv)
    fi

    log_success "Container Registry created successfully"
}

create_storage_account() {
    # Check if Storage Account already exists
    log_info "Checking if Storage Account '${STORAGE_ACCOUNT_NAME}' exists..."

    if [[ "$DRY_RUN" != "true" ]]; then
        local storage_exists=$(az storage account show --name "${STORAGE_ACCOUNT_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" --query "name" --output tsv 2>/dev/null || echo "")

        if [[ -n "$storage_exists" ]]; then
            log_info "Storage Account '${STORAGE_ACCOUNT_NAME}' already exists, skipping creation"

            # Still export the variables for existing storage account
            export STORAGE_ACCOUNT_KEY=$(az storage account keys list --account-name "${STORAGE_ACCOUNT_NAME}" --query "[0].value" -o tsv)

            # Check if container exists
            local container_exists=$(az storage container show --name "${AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME}" --account-name "${STORAGE_ACCOUNT_NAME}" --account-key "${STORAGE_ACCOUNT_KEY}" --query "name" --output tsv 2>/dev/null || echo "")

            if [[ -z "$container_exists" ]]; then
                execute_command "Creating storage container: ${AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME}" \
                    az storage container create \
                    --name "${AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME}" \
                    --account-name "${STORAGE_ACCOUNT_NAME}" \
                    --output table \
                    --account-key "${STORAGE_ACCOUNT_KEY}"
            else
                log_info "Storage container '${AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME}' already exists"
            fi

            # Store secrets in Key Vault (update existing if needed)
            execute_command "Storing storage account name in Key Vault" \
                az keyvault secret set \
                --vault-name "${KEYVAULT_NAME}" \
                --name "AKS-AIRFLOW-LOGS-STORAGE-ACCOUNT-NAME" \
                --value "${STORAGE_ACCOUNT_NAME}"

            execute_command "Storing storage account key in Key Vault" \
                az keyvault secret set \
                --vault-name "${KEYVAULT_NAME}" \
                --name "AKS-AIRFLOW-LOGS-STORAGE-ACCOUNT-KEY" \
                --value "${STORAGE_ACCOUNT_KEY}"

            log_success "Storage Account variables set for existing account"
            return 0
        fi
    else
        log_info "DRY_RUN mode: Would check for existing Storage Account '${STORAGE_ACCOUNT_NAME}'"
    fi

    # Create Storage Account if it doesn't exist
    execute_command "Creating Azure Storage Account: ${STORAGE_ACCOUNT_NAME}" \
        az storage account create \
        --name "${STORAGE_ACCOUNT_NAME}" \
        --resource-group "${RESOURCE_GROUP_NAME}" \
        --location "${AZURE_LOCATION}" \
        --sku Standard_ZRS \
        --output table

    if [[ "$DRY_RUN" != "true" ]]; then
        export STORAGE_ACCOUNT_KEY=$(az storage account keys list --account-name "${STORAGE_ACCOUNT_NAME}" --query "[0].value" -o tsv)

        execute_command "Creating storage container: ${AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME}" \
            az storage container create \
            --name "${AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME}" \
            --account-name "${STORAGE_ACCOUNT_NAME}" \
            --output table \
            --account-key "${STORAGE_ACCOUNT_KEY}"

        # Store secrets in Key Vault
        execute_command "Storing storage account name in Key Vault" \
            az keyvault secret set \
            --vault-name "${KEYVAULT_NAME}" \
            --name "AKS-AIRFLOW-LOGS-STORAGE-ACCOUNT-NAME" \
            --value "${STORAGE_ACCOUNT_NAME}"

        execute_command "Storing storage account key in Key Vault" \
            az keyvault secret set \
            --vault-name "${KEYVAULT_NAME}" \
            --name "AKS-AIRFLOW-LOGS-STORAGE-ACCOUNT-KEY" \
            --value "${STORAGE_ACCOUNT_KEY}"
    fi

    log_success "Storage Account created successfully"
}

create_aks_cluster() {
    # Check if AKS cluster already exists
    log_info "Checking if AKS cluster '${CLUSTER_NAME}' exists..."

    if [[ "$DRY_RUN" != "true" ]]; then
        local cluster_exists=$(az aks show --name "${CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" --query "name" --output tsv 2>/dev/null || echo "")

        if [[ -n "$cluster_exists" ]]; then
            log_info "AKS cluster '${CLUSTER_NAME}' already exists, skipping creation"

            # Still export the variables for existing cluster
            export OIDC_URL=$(az aks show --resource-group "${RESOURCE_GROUP_NAME}" --name "${CLUSTER_NAME}" --query oidcIssuerProfile.issuerUrl --output tsv)
            export KUBELET_IDENTITY=$(az aks show -g "${RESOURCE_GROUP_NAME}" --name "${CLUSTER_NAME}" --output tsv --query identityProfile.kubeletidentity.objectId)

            # Check if ACR role assignment exists
            local role_assignment_exists=$(az role assignment list --assignee "${KUBELET_IDENTITY}" --role "AcrPull" --scope "${ACR_REGISTRY_ID}" --query "[].roleDefinitionName" --output tsv 2>/dev/null || echo "")

            if [[ -z "$role_assignment_exists" ]]; then
                execute_command "Assigning AcrPull role to kubelet identity" \
                    az role assignment create \
                    --assignee "${KUBELET_IDENTITY}" \
                    --role "AcrPull" \
                    --scope "${ACR_REGISTRY_ID}" \
                    --output table
            else
                log_info "AcrPull role assignment already exists for kubelet identity"
            fi

            log_success "AKS cluster variables set for existing cluster"
            return 0
        fi
    else
        log_info "DRY_RUN mode: Would check for existing AKS cluster '${CLUSTER_NAME}'"
    fi

    # Create AKS cluster if it doesn't exist
    execute_command "Creating AKS cluster: ${CLUSTER_NAME}" \
        az aks create \
        --location "${AZURE_LOCATION}" \
        --name "${CLUSTER_NAME}" \
        --tier standard \
        --resource-group "${RESOURCE_GROUP_NAME}" \
        --network-plugin azure \
        --node-vm-size "${AKS_VM_SIZE}" \
        --node-count "${AKS_NODE_COUNT}" \
        --auto-upgrade-channel stable \
        --node-os-upgrade-channel NodeImage \
        --attach-acr "${ACR_REGISTRY}" \
        --enable-oidc-issuer \
        --enable-blob-driver \
        --enable-workload-identity \
        --generate-ssh-keys \
        --output table

    if [[ "$DRY_RUN" != "true" ]]; then
        export OIDC_URL=$(az aks show --resource-group "${RESOURCE_GROUP_NAME}" --name "${CLUSTER_NAME}" --query oidcIssuerProfile.issuerUrl --output tsv)
        export KUBELET_IDENTITY=$(az aks show -g "${RESOURCE_GROUP_NAME}" --name "${CLUSTER_NAME}" --output tsv --query identityProfile.kubeletidentity.objectId)

        execute_command "Assigning AcrPull role to kubelet identity" \
            az role assignment create \
            --assignee "${KUBELET_IDENTITY}" \
            --role "AcrPull" \
            --scope "${ACR_REGISTRY_ID}" \
            --output table
    fi

    log_success "AKS cluster created successfully"
}

# Connect to AKS cluster
connect_to_cluster() {
    if command -v kubectl &> /dev/null; then
        execute_command "Connecting to AKS cluster: ${CLUSTER_NAME}" \
            az aks get-credentials \
            --resource-group "${RESOURCE_GROUP_NAME}" \
            --name "${CLUSTER_NAME}" \
            --overwrite-existing \
            --output table

        log_success "Connected to AKS cluster successfully"
    else
        log_warning "kubectl not found. Skipping cluster connection."
    fi
}

# Export environment variables to file
export_variables() {
    local env_file="${ENVIRONMENT}.env"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would export variables to: ${env_file}"
        return 0
    fi

    cat > "${env_file}" << EOF
# Azure Airflow Infrastructure - ${ENVIRONMENT} Environment
# Generated on $(date)

export ENVIRONMENT=${ENVIRONMENT}
export AZURE_LOCATION=${AZURE_LOCATION}
export RESOURCE_GROUP_NAME=${RESOURCE_GROUP_NAME}
export IDENTITY_NAME=${IDENTITY_NAME}
export ACR_REGISTRY=${ACR_REGISTRY}
export KEYVAULT_NAME=${KEYVAULT_NAME}
export CLUSTER_NAME=${CLUSTER_NAME}
export STORAGE_ACCOUNT_NAME=${STORAGE_ACCOUNT_NAME}

# Service configuration
export SERVICE_ACCOUNT_NAME=${SERVICE_ACCOUNT_NAME}
export SERVICE_ACCOUNT_NAMESPACE=${SERVICE_ACCOUNT_NAMESPACE}
export AKS_AIRFLOW_NAMESPACE=${AKS_AIRFLOW_NAMESPACE}
export AKS_AIRFLOW_CLUSTER_NAME=${AKS_AIRFLOW_CLUSTER_NAME}
export AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME=${AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME}
export AKS_AIRFLOW_LOGS_STORAGE_SECRET_NAME=${AKS_AIRFLOW_LOGS_STORAGE_SECRET_NAME}

# Resource IDs (only available after creation)
${IDENTITY_ID:+export IDENTITY_ID=${IDENTITY_ID}}
${IDENTITY_PRINCIPAL_ID:+export IDENTITY_PRINCIPAL_ID=${IDENTITY_PRINCIPAL_ID}}
${IDENTITY_CLIENT_ID:+export IDENTITY_CLIENT_ID=${IDENTITY_CLIENT_ID}}
${KEYVAULT_ID:+export KEYVAULT_ID=${KEYVAULT_ID}}
${KEYVAULT_URL:+export KEYVAULT_URL=${KEYVAULT_URL}}
${ACR_REGISTRY_ID:+export ACR_REGISTRY_ID=${ACR_REGISTRY_ID}}
${OIDC_URL:+export OIDC_URL=${OIDC_URL}}
${KUBELET_IDENTITY:+export KUBELET_IDENTITY=${KUBELET_IDENTITY}}
EOF

    log_success "Environment variables exported to: ${env_file}"
}

# Main execution function

log_info "Starting Azure Airflow Infrastructure Provisioning"
parse_arguments "$@"
validate_environment
setup_variables
check_prerequisites

if [[ "$DRY_RUN" == "true" ]]; then
    log_warning "DRY-RUN MODE: No actual resources will be created"
fi

# Execute provisioning steps
create_resource_group
create_managed_identity
create_key_vault
create_container_registry
create_storage_account
create_aks_cluster
connect_to_cluster
export_variables

log_success "Infrastructure provisioning completed successfully!"

if [[ "$DRY_RUN" != "true" ]]; then
    log_info "Next steps:"
    log_info "1. Source the environment file: source ${ENVIRONMENT}.env"
    log_info "2. Deploy Airflow using Helm or your preferred method"
    log_info "3. Configure workload identity for Airflow pods"
fi
