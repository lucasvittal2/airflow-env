#!/bin/bash

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# Script: deploy-airflow.sh
# Description: Deploy Apache Airflow on AKS with External Secrets Operator
# Usage: ./deploy-airflow.sh [OPTIONS]
# CI/CD Usage: ./deploy-airflow.sh --ci-mode

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Deploy Apache Airflow on AKS with External Secrets Operator

OPTIONS:
    -h, --help              Show this help message
    -c, --ci-mode           Run in CI/CD mode (no interactive prompts)
    -n, --namespace NAME    Airflow namespace (default: airflow)
    -s, --service-account   Service account name (default: airflow)
    -v, --values-file FILE  Airflow values file (default: airflow_values.yaml)
    -cr, --container-registry Container Registry to push containers
    --skip-port-forward     Skip port forwarding (useful for CI/CD)
    --dry-run              Show what would be executed without running

Environment Variables Required:
    IDENTITY_NAME            - Azure User-Assigned Identity name
    RESOURCE_GROUP_NAME      - Azure Resource Group name
    KEYVAULT_NAME           - Azure Key Vault name
    IDENTITY_NAME_PRINCIPAL_ID - Azure Identity Principal ID
    OIDC_URL                   - AKS OIDC Issuer URL

Optional Environment Variables:
    HELM_TIMEOUT               - Helm timeout (default: 10m)
    KUBECTL_TIMEOUT            - Kubectl timeout (default: 300s)

EOF
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to validate prerequisites
validate_prerequisites() {
    log_info "Validating prerequisites..."

    local missing_commands=()

    # Check required commands
    for cmd in az helm kubectl; do
        if ! command_exists "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done

    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing_commands[*]}"
        log_error "Please install the missing commands and try again"
        exit 1
    fi

    # Check Azure CLI login
    if ! az account show >/dev/null 2>&1; then
        log_error "Azure CLI not logged in. Please run 'az login'"
        exit 1
    fi

    log_success "Prerequisites validation completed"
}

# Function to validate environment variables
validate_environment() {
    log_info "Validating environment variables..."

    local required_vars=(
        "IDENTITY_NAME"
        "RESOURCE_GROUP_NAME"
        "KEYVAULT_NAME"
        "IDENTITY_NAME_PRINCIPAL_ID"
        "OIDC_URL"
    )

    local missing_vars=()

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required environment variables:"
        printf '%s\n' "${missing_vars[@]}" | sed 's/^/  - /'
        log_error "Please set these variables and try again"
        exit 1
    fi

    # Check if airflow values file exists
    if [[ ! -f "$AIRFLOW_VALUES_FILE" ]]; then
        log_error "Airflow values file not found: $AIRFLOW_VALUES_FILE"
        exit 1
    fi

    log_success "Environment validation completed"
}

# Function to execute command with logging
execute_command() {
    local cmd="$1"
    local description="$2"

    log_info "$description"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would execute: $cmd"
        return 0
    fi

    if eval "$cmd"; then
        log_success "$description completed"
        return 0
    else
        log_error "$description failed"
        return 1
    fi
}

# Function to check if helm release exists
helm_release_exists() {
    local release_name="$1"
    local namespace="$2"

    helm list -n "$namespace" -q | grep -q "^${release_name}$"
}

# Function to check if federated credential exists
federated_credential_exists() {
    local identity_name="$1"
    local resource_group="$2"
    local credential_name="$3"

    az identity federated-credential list \
        --identity-name "$identity_name" \
        --resource-group "$resource_group" \
        --query "[?name=='$credential_name']" \
        --output tsv | grep -q .
}

install_secret_operator() {
  local namespace=$1
  local helm_repo="external-secrets"
  local helm_repo_url="https://charts.external-secrets.io"
  local helm_chart="external-secrets/external-secrets"
  local release_name="external-secrets"

  log_info "Installing secret operator from helm..."

  # Add helm repo (skip if already exists)
  if ! helm repo add "${helm_repo}" "${helm_repo_url}" >/dev/null 2>&1; then
    log_warning "Helm repository ${helm_repo} already exists, continuing..."
  fi

  # Update helm repos
  if ! helm repo update >/dev/null 2>&1; then
    log_error "Failed to update helm repositories"
    return 1
  fi

  # Check if release already exists
  if helm status "${release_name}" --namespace "${namespace}" >/dev/null 2>&1; then
    log_warning "Release ${release_name} already exists in namespace ${namespace}. Attempting upgrade..."

    # Try to upgrade instead of install
    if ! helm upgrade "${release_name}" "${helm_chart}" \
      --namespace "${namespace}" \
      --set installCRDs=true \
      --wait >/dev/null 2>&1; then
      log_error "Failed to upgrade existing release ${release_name}"
      return 1
    fi

    log_success "Successfully upgraded secret operator in namespace ${namespace}"
    return 0
  fi

  # If release doesn't exist, proceed with fresh install
  if ! helm install "${release_name}" "${helm_chart}" \
    --namespace "${namespace}" \
    --create-namespace \
    --set installCRDs=true \
    --wait >/dev/null 2>&1; then
    log_error "Failed to install secret operator in namespace ${namespace}"
    return 1
  fi

  log_success "Secret operator installed successfully in namespace ${namespace}"
  return 0
}

# Main deployment function
deploy_airflow() {
    log_info "Starting Airflow deployment on AKS..."
    local PORT_FORWARD=$1
    # Get tenant ID
    log_info "Getting Azure tenant ID..."
    if ! TENANT_ID=$(az account show --query tenantId -o tsv); then
        log_error "Failed to get tenant ID"
        exit 1
    fi
    export TENANT_ID
    log_info "Tenant ID: $TENANT_ID"

    # Add and update helm repositories
    log_info "Setting up Helm repositories..."
    execute_command "helm repo add external-secrets https://charts.external-secrets.io" \
        "Adding external-secrets Helm repository"

    execute_command "helm repo add apache-airflow https://airflow.apache.org" \
        "Adding apache-airflow Helm repository"

    execute_command "helm repo update" \
        "Updating Helm repositories"

    # Install external-secrets if not already installed
    if helm_release_exists "external-secrets" "$AKS_AIRFLOW_NAMESPACE"; then
        log_warning "External Secrets Operator already installed, skipping..."
    else
        log_info "Installing External Secrets Operator..."
        execute_command "helm install external-secrets external-secrets/external-secrets \
            --namespace ${AKS_AIRFLOW_NAMESPACE} \
            --create-namespace \
            --set installCRDs=true \
            --timeout ${HELM_TIMEOUT} \
            --wait" \
            "Installing External Secrets Operator"
    fi

    # Create federated credential if it doesn't exist
    if federated_credential_exists "$IDENTITY_NAME" "$RESOURCE_GROUP_NAME" "external-secret-operator"; then
        log_warning "Federated credential 'external-secret-operator' already exists, skipping..."
    else
        log_info "Creating federated credential..."
        az identity federated-credential create \
            --name external-secret-operator \
            --identity-name ${IDENTITY_NAME} \
            --resource-group ${RESOURCE_GROUP_NAME} \
            --issuer ${OIDC_URL} \
            --audience api://AzureADTokenExchange \
            --subject system:serviceaccount:${AKS_AIRFLOW_NAMESPACE}:${SERVICE_ACCOUNT_NAME} \
            --output tsv
    fi

    # Set Key Vault permissions
    log_info "Setting Key Vault permissions..."
    execute_command "az keyvault set-policy \
        --name $KEYVAULT_NAME \
        --object-id $IDENTITY_NAME_PRINCIPAL_ID \
        --secret-permissions get \
        --output table" \
        "Setting Key Vault permissions"

    # Search for airflow helm repository to verify
    log_info "Verifying Airflow Helm repository..."
    execute_command "helm search repo airflow" \
        "Searching Airflow Helm repository"

    # Validate custom chart exists
    if [[ ! -f "./helm/Chart.yaml" ]]; then
        log_error "Custom Helm chart not found at ./helm/Chart.yaml"
        exit 1
    fi

    # Update helm dependencies for custom chart (if any)
    log_info "Updating Helm dependencies for custom chart..."
    execute_command "helm dependency update ./helm" \
        "Updating custom chart dependencies"

    # Install/Upgrade Custom Airflow Chart
    if helm_release_exists "airflow" "$AKS_AIRFLOW_NAMESPACE"; then
        log_warning "Apache Airflow already installed, upgrading..."
        execute_command "helm upgrade airflow ./helm \
            --namespace ${AKS_AIRFLOW_NAMESPACE} \
            -f ${AIRFLOW_VALUES_FILE} \
            --timeout ${HELM_TIMEOUT} \
            --atomic \
            --debug \
            --wait" \
            "Upgrading Custom Airflow Chart"
    else
        log_info "Installing Custom Airflow Chart..."
        execute_command "helm install airflow ./helm \
            --namespace ${AKS_AIRFLOW_NAMESPACE} \
            --create-namespace \
            -f ${AIRFLOW_VALUES_FILE} \
            --timeout ${HELM_TIMEOUT} \
            --atomic \
            --debug \
            --wait" \
            "Installing Custom Airflow Helm Chart"
    fi

    # Verify Airflow installation
    log_info "Verifying Airflow installation..."
    execute_command "kubectl get pods -n ${AKS_AIRFLOW_NAMESPACE} --timeout=${KUBECTL_TIMEOUT}" \
        "Getting Airflow pods status"

    # Wait for pods to be ready
    log_info "Waiting for Airflow pods to be ready..."
    if [[ "$DRY_RUN" != "true" ]]; then
        if kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=airflow -n "$AKS_AIRFLOW_NAMESPACE" --timeout="$KUBECTL_TIMEOUT"; then
            log_success "All Airflow pods are ready"
        else
            log_error "Timeout waiting for Airflow pods to be ready"
            kubectl get pods -n "$AKS_AIRFLOW_NAMESPACE"
            exit 1
        fi
    fi

    # Port forwarding (skip in CI mode)
    if [[ "$SKIP_PORT_FORWARD" != "true" ]]; then
        log_info "Setting up port forwarding to Airflow webserver..."
        log_info "Access Airflow UI at: http://localhost:${PORT_FORWARD}"
        log_info "Press Ctrl+C to stop port forwarding"

        if [[ "$DRY_RUN" != "true" ]]; then
            kubectl port-forward svc/airflow-webserver ${PORT_FORWARD}:8080 -n "$AKS_AIRFLOW_NAMESPACE"
        else
            log_info "[DRY-RUN] Would execute: kubectl port-forward svc/airflow-webserver ${PORT_FORWARD}:8080 -n $AKS_AIRFLOW_NAMESPACE"
        fi
    else
        log_info "Skipping port forwarding (CI mode or explicitly skipped)"
        log_info "To access Airflow UI later, run:"
        log_info "kubectl port-forward svc/airflow-webserver ${PORT_FORWARD}:8080 -n $AKS_AIRFLOW_NAMESPACE"
    fi

    log_success "Airflow deployment completed successfully!"
}

# Error handling function
cleanup_on_error() {
    local exit_code=$?
    log_error "Script failed with exit code $exit_code"

    if [[ "$CI_MODE" != "true" ]]; then
        log_info "Deployment failed. Check the logs above for details."
        log_info "You can check the status with:"
        log_info "  kubectl get pods -n $AKS_AIRFLOW_NAMESPACE"
        log_info "  helm list -n $AKS_AIRFLOW_NAMESPACE"
    fi

    exit $exit_code
}

# Set up error handling
trap cleanup_on_error ERR

# Main execution
## set secrets vars envs
source dev.env
## set Default values
AKS_AIRFLOW_NAMESPACE="airflow"
SERVICE_ACCOUNT_NAME="airflow"
AIRFLOW_VALUES_FILE="airflow_values.yaml"
CI_MODE=false
PORT_FORWARD=8080
SKIP_PORT_FORWARD=false
DRY_RUN=false
HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"
KUBECTL_TIMEOUT="${KUBECTL_TIMEOUT:-300s}"


## Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -c|--ci-mode)
            CI_MODE=true
            SKIP_PORT_FORWARD=true
            shift
            ;;
        -n|--namespace)
            AKS_AIRFLOW_NAMESPACE="$2"
            shift 2
            ;;
        -s|--service-account)
            SERVICE_ACCOUNT_NAME="$2"
            shift 2
            ;;
        -v|--values-file)
            AIRFLOW_VALUES_FILE="$2"
            shift 2
            ;;
        --skip-port-forward)
            SKIP_PORT_FORWARD=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -pf | --port-forward)
            PORT_FORWARD="$2"
            shift 2
            ;;
        -cr | --container-registry)
            ACR_NAME="$2"
            shift 2
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

log_info "Starting Airflow deployment script..."
log_info "Namespace: $AKS_AIRFLOW_NAMESPACE"
log_info "Service Account: $SERVICE_ACCOUNT_NAME"
log_info "Values File: $AIRFLOW_VALUES_FILE"
log_info "CI Mode: $CI_MODE"
log_info "Dry Run: $DRY_RUN"

IMAGES_LIST="apache/airflow:2.9.3 airflow:airflow-pgbouncer-2024.01.19-1.21.0 mher/flower:master bitnami/statsd-exporter:v0.26.1 airflow:airflow-pgbouncer-exporter-2024.06.18-0.17.0 openweb/git-sync:"
validate_prerequisites
validate_environment

install_secret_operator $AKS_AIRFLOW_NAMESPACE
deploy_airflow $PORT_FORWARD

log_success "Script completed successfully!"
