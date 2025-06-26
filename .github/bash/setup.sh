#!/bin/bash


# echo provisioning infrastructure on azure cloud

.devops/bash/provisioning.sh \
--environment hml \
--location canadacentral  \
--deploy-env azure --node-count 2 \
--subscription "Azure subscription 1" \
--vm-size Standard_B2ps_v2

kubectl create namespace ${AKS_AIRFLOW_NAMESPACE} --dry-run=client --output yaml | kubectl apply -f -
#deploy airflow on AKS
.devops/bash/deploy.sh  --environment hml

