#!/bin/bash


# echo provisioning infrastructure on azure cloud

.github/bash/provisioning.sh \
--environment dev \
--location canadacentral  \
--deploy-env azure --node-count 2 \
--subscription "Azure subscription 1" \
--vm-size Standard_B2ps_v2

kubectl create namespace ${AKS_AIRFLOW_NAMESPACE} --dry-run=client --output yaml | kubectl apply -f -
#deploy airflow on AKS
.github/bash/deploy.sh  --environment dev

kubectl port-forward svc/airflow-webserver  8080:8080 -n airflow
