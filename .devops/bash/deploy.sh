#!/bin/bash

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

while [[ $# -gt 0 ]]; do
    case "$1" in
        --environment) env="$2"; shift 2 ;;
        *) log_error "Unknown argument: $1"; print_usage ;;
    esac
done

# get global vars
source  "${env}.env"

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }



create_namespace_if_not_exists() {
  local NAMESPACE="${AKS_AIRFLOW_NAMESPACE}"

  log_info "Checking if namespace '$NAMESPACE' exists..."
  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    log_info "Namespace '$NAMESPACE' already exists. Skipping creation."
  else
    log_info "Namespace '$NAMESPACE' does not exist. Creating..."
    kubectl create namespace "$NAMESPACE" --dry-run=client --output yaml | kubectl apply -f -
    log_success "Namespace '$NAMESPACE' created."
  fi
}

install_external_secrets_plugin() {

  log_info "Checking if external-secrets Helm repo is added..."
  if ! helm repo list | grep -q '^external-secrets'; then
    log_info "Adding external-secrets Helm repo..."
    helm repo add external-secrets https://charts.external-secrets.io
    log_success "external-secrets Helm repo added."
  else
    log_info "external-secrets Helm repo already exists."
  fi

  log_info "Updating Helm repos..."
  helm repo update

  log_info "Checking if external-secrets release is installed in namespace '${AKS_AIRFLOW_NAMESPACE}'..."
  if ! helm status external-secrets --namespace "${AKS_AIRFLOW_NAMESPACE}" >/dev/null 2>&1; then
    log_info "Installing external-secrets plugin in namespace '${AKS_AIRFLOW_NAMESPACE}'..."
    helm install external-secrets \
      external-secrets/external-secrets \
      --namespace "${AKS_AIRFLOW_NAMESPACE}" \
      --create-namespace \
      --set installCRDs=true \
      --wait
    log_success "external-secrets plugin installed in namespace '${AKS_AIRFLOW_NAMESPACE}'."
  else
    log_info "External Secrets plugin is already installed in namespace ${AKS_AIRFLOW_NAMESPACE}."
  fi
}

create_airflow_git_ssh_secret_if_not_exists() {
  local SECRET_NAME="airflow-git-ssh-secret"
  local NAMESPACE="${AKS_AIRFLOW_NAMESPACE}"
  local SSH_KEY_PATH="$HOME/.ssh/airflowsshkey.pub"

  log_info "Checking if secret '$SECRET_NAME' exists in namespace '$NAMESPACE'..."
  if kubectl get secret "$SECRET_NAME" --namespace "$NAMESPACE" >/dev/null 2>&1; then
    log_info "Secret '$SECRET_NAME' already exists in namespace '$NAMESPACE'. Skipping creation."
  else
    log_info "Secret '$SECRET_NAME' does not exist. Creating..."
    kubectl create secret generic "$SECRET_NAME" \
      --from-file=gitSshKey="$SSH_KEY_PATH" \
      --namespace "$NAMESPACE"
    log_success "Secret '$SECRET_NAME' created in namespace '$NAMESPACE'."
  fi
}
generate_values_yaml() {
  local env_file="$1.env"
  local template_file="helm/airflow/values.template.yaml"
  local output_file="helm/airflow/values.yaml"

  # Export all variables from the env file
  set -a
  source "$env_file"
  set +a

  # Map variable names in .env to placeholders in the template
  declare -A mapping=(
    [AKS_AIRFLOW_NAMESPACE]="$AKS_AIRFLOW_NAMESPACE"
    [AZ_TENANT_ID]="$TENANT_ID"
    [SERVICE_ACCOUNT_NAME]="$SERVICE_ACCOUNT_NAME"
    [MY_IDENTITY_NAME]="$MY_IDENTITY_NAME"
    [KEYVAULT_URL]="$KEYVAULTURL"
    [AKS_AIRFLOW_LOGS_STORAGE_SECRET_NAME]="$AKS_AIRFLOW_LOGS_STORAGE_SECRET_NAME"
    [AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME]="$AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME"
    [AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME]="$AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME"
    [MY_RESOURCE_GROUP_NAME]="$MY_RESOURCE_GROUP_NAME"
    [MY_IDENTITY_NAME_CLIENT_ID]="$MY_IDENTITY_NAME_CLIENT_ID"
    [TENANT_ID]="$TENANT_ID"
    [KEYVAULTURL]="$KEYVAULTURL"
    [MY_ACR_REGISTRY]="$MY_ACR_REGISTRY"
  )

  # Read the template into a variable
  local content
  content=$(<"$template_file")

  # Replace placeholders with values from mapping
  for key in "${!mapping[@]}"; do
    value="${mapping[$key]}"
    # Escape forward slashes for sed
    esc_value=$(printf '%s' "$value" | sed -e 's/[\/&]/\\&/g')
    # Replace both <VAR> and <VAR_NAME>
    content=$(echo "$content" | sed "s/<$key>/$esc_value/g")
  done

  # Save to output
  echo "$content" > "$output_file"
  echo "Generated $output_file"
}

install_or_upgrade_airflow_chart() {
  local RELEASE_NAME="airflow"
  local NAMESPACE="${AKS_AIRFLOW_NAMESPACE}"
  local VALUES_FILE="helm/airflow/values.yaml"
  local CHART_VERSION="1.15.0"
  local CHART_REPO="apache-airflow"
  local CHART_NAME="airflow"
  local CHART_FULL="helm/${CHART_NAME}"

  log_info "Adding and updating Helm repo for Airflow..."
  helm repo add "$CHART_REPO" https://airflow.apache.org
  helm repo update
  cd "$CHART_FULL"
  helm dependency build
  cd "../../"
  log_info "Checking if Airflow release exists in namespace '$NAMESPACE'..."
  if helm status "$RELEASE_NAME" --namespace "$NAMESPACE" >/dev/null 2>&1; then
    log_info "Airflow release already exists in namespace '$NAMESPACE'. Upgrading chart..."
    helm upgrade "$RELEASE_NAME" "$CHART_FULL" \
      --namespace "$NAMESPACE" \
      -f "$VALUES_FILE" \
      --version "$CHART_VERSION" \
      --debug
    log_success "Airflow chart upgraded in namespace '$NAMESPACE'."
  else
    log_info "Airflow release does not exist in namespace '$NAMESPACE'. Installing chart..."

    helm install "$RELEASE_NAME" "$CHART_FULL" \
      --namespace "$NAMESPACE" \
      --create-namespace \
      -f "$VALUES_FILE" \
      --version "$CHART_VERSION" \
      --debug
    log_success "Airflow chart installed in namespace '$NAMESPACE'."
  fi

  log_info "Listing pods in namespace '$NAMESPACE' after Airflow install/upgrade:"
  kubectl get pods -n "$NAMESPACE"
  rm $VALUES_FILE
}

port_forward_airflow_webserver_if_available() {
  local NAMESPACE="${AKS_AIRFLOW_NAMESPACE}"
  local LOCAL_PORT=$1
  local REMOTE_PORT=8080
  local SERVICE_NAME="airflow-webserver"

  log_info "Checking if local port $LOCAL_PORT is available for port-forward..."
  if lsof -i :"$LOCAL_PORT" >/dev/null 2>&1; then
    log_warning "Local port $LOCAL_PORT is already in use. Skipping port-forward."
  else
    log_info "Local port $LOCAL_PORT is available. Starting port-forward to Airflow webserver..."
    kubectl port-forward svc/"$SERVICE_NAME" "$LOCAL_PORT":"$REMOTE_PORT" -n "$NAMESPACE"
  fi
}

log_info "Starting Airflow setup steps..."
create_namespace_if_not_exists
create_airflow_git_ssh_secret_if_not_exists
generate_values_yaml $env
install_external_secrets_plugin
install_or_upgrade_airflow_chart
log_info "Starting port-forward for Airflow webserver..."
port_forward_airflow_webserver_if_available 9090
log_success "Script execution completed."