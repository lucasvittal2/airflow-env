# Airflow on Kubernetes with Helm

This repository provides an automated solution to deploy Apache Airflow on a Kubernetes cluster using Helm charts. The main goal is to simplify the provisioning and deployment process, making it easy to deploy a fully functional Airflow production like environment running on main cloud players (GOOGLE, Azure, AWS) with minimal manual intervention.

## Features

- **Automated Infrastructure Provisioning**: Scripts to provision Azure resources and AKS.
- **Namespace Management**: Automatic creation and application of the Kubernetes namespace.
- **Airflow Deployment**: Deploys Airflow on AKS using Helm charts.
- **Configurable Environment**: Easily adjust environment, location, node count, and VM size.
- **Automated upload of Dags**: Dags are automatically uploaded to airflow using gitSync plugin. If user want to deploy a dag to airflow env, just need to push it to git of this project.

## Prerequisites

- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)
- Sufficient Azure permissions to provision resources
- Bash shell environment

## Getting Started

### 1. Clone the Repository

```bash
git clone https://github.com/your-username/your-repo.git
cd your-repo
```

### 2. Provision Infrastructure and Deploy Airflow

Run the provided script to provision infrastructure and deploy Airflow:

```bash
#!/bin/bash

# Exemple of running provision.sh infrastructure on Azure Cloud
.devops/bash/provisioning.sh \
  --environment dev \
  --location canadacentral  \
  --deploy-env azure --node-count 2 \
  --subscription "Azure subscription 1" \
  --vm-size Standard_B2ps_v2

# Create the Kubernetes namespace (if it doesn't exist)
kubectl create namespace ${AKS_AIRFLOW_NAMESPACE} --dry-run=client --output yaml | kubectl apply -f -

# Deploy Airflow on AKS using Helm
.devops/bash/deploy.sh --environment dev
```

> **Note:** Replace the values for `--environment`, `--location`, `--subscription`, and `--vm-size` as needed for your setup.
### 3. Deploy airflow on Cloud Cluster using kubernetes and helm
```shell
.devops/bash/deploy.sh  --environment dev
```
### 4. Accessing Airflow

After follow all guides until here, you can access your airflow env on `localhost:9090` with default airflow credentials.

## Customization

- **Node Count:** Adjust with `--node-count` to scale your cluster.
- **VM Size:** Select a different size with `--vm-size` as per your workload.
- **Environment:** Use custom names for different deployments (e.g., `dev`, `prod`).

## Guidelines

- Use the provided scripts to ensure consistency and repeatability.
- Always check for required environment variables before running the scripts.
- Review and update Helm values in the chart directory as needed for your use case.

## Troubleshooting

- Ensure you are logged in to Azure and have the correct subscription set.
- Check `kubectl` context is pointing to the correct AKS cluster.
- Review script logs for any errors during provisioning or deployment.

## License

[MIT License](LICENSE)

## Contributing

Feel free to submit issues or pull requests to improve this repository!
