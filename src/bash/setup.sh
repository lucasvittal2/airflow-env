# echo provisioning infrastructure on azure cloud
src/bash/provisioning.sh --environment dev --location canadacentral --resource-group apache-airflow-env --node-count 2 --subscription "Azure subscription 1" --vm-size Standard_D2ps_v6

#setup airflow with helm