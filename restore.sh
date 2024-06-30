#!/bin/bash -x

GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'
# Add Hashicorp Helm Repository

contexts=$(kubectl config get-contexts -o name)
contextsforselect=$contexts" New-Context"
clusters=($(kubectl config get-clusters | tail -n +2))
users=($(kubectl config get-users | tail -n +2))

echo -e"${GREEN}***** Select or 'compose' the Kubernetes Context, where the Vault is located: *****${RESET}"
select context in $contextsforselect; do
  if [[ -n $context ]]; then
    echo -e"${GREEN}***** You selected: $context *****${RESET}"
    if [ "$context" = "${contextsforselect##* }" ]; then
      echo "Creating the context..."
      echo "Please select the cluster:"
      select selected_cluster in "${clusters[@]}"; do
        if [[ -n "$selected_cluster" ]]; then
          echo -e"${GREEN}***** Selected cluster: $selected_cluster *****${RESET}"
          break
        else
          echo -e "${RED}***** Invalid selection. Please try again. *****${RESET}"
        fi
      done
      
      echo "Please select the user:"
      select selected_user in "${users[@]}"; do
        if [[ -n "$selected_user" ]]; then
          echo -e "${GREEN}***** Selected cluster: $selected_user *****${RESET}"
          break
        else
          echo -e "${RED}***** Invalid selection. Please try again. *****${RESET}"
        fi
      done

      read -p "Enter the context name: " new_context

      kubectl config set-context "$new_context" --cluster="$selected_cluster" --user="$selected_user"
      if [ $? -eq 0 ]; then
        echo "Context '$new_context' created successfully."
      else
        echo -e "${RED}***** Failed to create context. *****${RESET}"
        exit 1
      fi

      kubectl config use-context "$new_context"
      if [ $? -ne 0 ]; then
        echo -e "${RED}***** Failed to switch to context '$new_context'. *****${RESET}"
        exit 1
      fi
    else
      kubectl config use-context $context
      if [ $? -ne 0 ]; then
        echo -e "${RED}***** Failed to switch to context '$context'. *****${RESET}"
        exit 1
      fi
    fi
    if kubectl get pods > /dev/null 2>&1; then
        echo "Credentials are valid."
      else
        echo -e "${RED}***** Invalid credentials or insufficient permissions. Provide new credentials with kubectl or via the ~/.kube/config *****${RESET}"
        exit 1
      fi

      namespace=$(kubectl config view --minify --output 'jsonpath={..namespace}')

      while true; do
        kubectl get namespace "$namespace" &> /dev/null
        if [ $? -ne 0 ]; then
          echo "Namespace '$namespace' does not exist or you don't have permissions for it."
          read -p "Please enter a valid namespace: " namespace
          continue
        fi

        kubectl auth can-i get pods --namespace="$namespace" &> /dev/null
        if [ $? -ne 0 ]; then
          echo "You do not have access to the namespace '$namespace'."
          read -p "Please enter a valid namespace: " namespace
          continue
        fi

        echo "Namespace '$namespace' exists and you have access to it."
        kubectl config set-context --current --namespace="$namespace"
        break
      done
    break
  else
    echo -e "${RED}***** Invalid selection. Please try again. *****${RESET}"
  fi
done

helm_releases=$(helm list -q)
if [ -z "$helm_releases" ]
then
    echo -e "${RED}***** No Helm releases found in the current namespace. *****${RESET}"
    exit 1
fi

declare -A vault_configs

echo "Please select an installed Vault Helm Release: "
select release in $helm_releases; do
  if [ -n "$release" ]; then
    echo -e "${GREEN}*****You selected: $release *****${RESET}"
    break
  else
    echo -e "${RED}***** Invalid selection. Please try again. *****${RESET}"
  fi
done

if kubectl get statefulset -l app.kubernetes.io/instance=${vault_configs[release_name]} | grep vault > /dev/null 2>&1; then
  echo "There is indeed a Vault StatefulSet."
else
  echo -e "${RED}***** Selected Helm Release is not a Vault Helm Release - there are no StatefulSets with 'vault' in the name. *****${RESET}"
  exit 1
fi

vault_configs[release_name]=$release
vault_configs[ss_name]=$(kubectl get statefulset -l app.kubernetes.io/instance=${vault_configs[release_name]} -o="jsonpath={.items[0].metadata.name}")
vault_configs[jsonvalues]=$(helm get values ${vault_configs[release_name]} -ojson)
if [ $(echo ${vault_configs[jsonvalues]} | jq -r '.server.standalone.enabled') = true ];
then
  vault_configs[replicas]=1
else
  vault_configs[replicas]=$(echo ${vault_configs[jsonvalues]} | jq -r '.server.ha.replicas')
fi

echo -e "${RED}!!!!! Deleting 'old' Vault Pods and their PVCs !!!!!${RESET}"
kubectl scale statefulsets ${vault_configs[ss_name]} --replicas=0 && sleep 15
kubectl delete pvc $(kubectl get pvc -lapp.kubernetes.io/instance=${vault_configs[release_name]} -ojson | jq -r '.items[].metadata.name')
echo -e "${GREEN}***** Recreating the Vault Cluster from scratch. *****${RESET}"
kubectl scale statefulsets ${vault_configs[ss_name]} --replicas=${vault_configs[replicas]}

echo "Generating new Shamir Keys."
read -p "Enter the number of key shares for Vault Cluster ${vault_configs[release_name]}: " key_shares
read -p "Enter the number of key threshold for Vault Cluster ${vault_configs[release_name]}: " key_threshold

while ((key_threshold > key_shares))
do
  echo "The key threshold should be equal or less than the number of key shares. Please enter again."
  read -p "Enter the number of key threshold for Vault Cluster ${vault_configs[release_name]}: " key_threshold
done

pod_downtime () {
  if [ ${vault_configs[replicas]} -ne 1 ] ; 
  then
    until [ $(kubectl get pods -lapp.kubernetes.io/instance=${vault_configs[release_name]},vault-version -ojson | jq -j '.items | length') -eq ${vault_configs[replicas]} ]
    do
      echo -e "${GREEN}***** Waiting until every pod @${vault_configs[release_name]} Helm Release is reachable... *****${RESET}"
      sleep 10
    done
  else
    until [ $(kubectl get pods -lapp.kubernetes.io/instance=${vault_configs[release_name]} --field-selector=status.phase==Running -ojson | jq -j '.items | length') -eq ${vault_configs[replicas]} ]
    do
      echo -e "${GREEN}***** Waiting until every pod @${vault_configs[release_name]} Helm Release is reachable... *****${RESET}"
      sleep 10
    done
  fi
}

pod_downtime

echo -e "${GREEN}***** RE-Initiating the first pod (${vault_configs[ss_name]}-0). New keys and root token will be available in the vault.json file... *****${RESET}"
initout=$(kubectl exec ${vault_configs[ss_name]}-0 -- vault operator init -key-shares=$key_shares -key-threshold=$key_threshold -format=json) && echo $initout > vault.json
# Unsealing replicas

unseal_node () {
  j=0
  PROGRESS=99
  sleep 7
  echo -e "${GREEN}***** Unsealing $1... *****${RESET}"
  until [ $PROGRESS -eq 0 ]
  do
    KEY=$(jq --arg j $j -r ".unseal_keys_hex[$j]" vault.json)
    # Unsealing!
    PROGRESS=$(kubectl exec $1 -- vault operator unseal -format=json $KEY | jq -j '.progress')
    j=$((j+1))
  done
}

for (( i=0; i<${vault_configs[replicas]}; i++ )) ;
do
  unseal_node ${vault_configs[ss_name]}-$i
done

while true; do
  echo -e "${GREEN}***** Backup location - Do you need to provide new S3 credentials (y) or using S3 data from the *vaults-snapshot-s3* secret (n)? *****${RESET}"
  read -p "Providing new S3 credentials? (y/n) " yn
  case $yn in
    [yY] ) echo "Ok, asking for credentials..."
      read -p "Enter the S3 server address: (example - s3.loc.icdc.io)" s3_endpoint
      s3_endpoint="https://$s3_endpoint/"
      read -p "Enter the S3 Access Key ID: " s3_access_key_id
      read -p "Enter the S3 Secret Access Key: " -s s3_secret_access_key
      read -p "Enter the bucket name for the ${vault_configs[release_name]}: " s3_bucket
            ;;
    [nN] ) echo "Ok, using S3 data from the secrets/vaults-snapshot-s3."
      s3_endpoint=$(kubectl get secrets/vaults-snapshot-s3 --template={{.data.AWS_ENDPOINT}} | base64 -d)
      s3_access_key_id=$(kubectl get secrets/vaults-snapshot-s3 --template={{.data.AWS_ACCESS_KEY_ID}} | base64 -d)
      s3_secret_access_key=$(kubectl get secrets/vaults-snapshot-s3 --template={{.data.AWS_SECRET_ACCESS_KEY}} | base64 -d)
      s3_bucket=$(kubectl get cronjobs.batch/${vault_configs[release_name]}-snapshot-cronjob -ojson | jq -r '.spec.jobTemplate.spec.template.spec.containers[1].env[0].value')
            ;;
    * ) echo -e "${RED}***** Invalid response. Please enter y or n. *****${RESET}";;
  esac
  # Exit the loop after a valid choice (y or n)
  break
done


backup_files=$((s3cmd ls --access_key=$s3_access_key_id --secret_key=$s3_secret_access_key --host=${s3_endpoint::-1} --host-bucket=${s3_endpoint}%\(bucket\) s3://$s3_bucket) | awk '{print $4}')

echo -e "${GREEN}*****  Please select the backup file you wish to restore Vault from: *****${RESET}"
select backup in $backup_files; do
  if [ -n "$backup" ]; then
    echo "You selected: $backup"

    echo "Generating URL for selected backup file"
    backup_url=$(s3cmd signurl --access_key=$s3_access_key_id --secret_key=$s3_secret_access_key --host=${s3_endpoint::-1} --host-bucket=${s3_endpoint}%\(bucket\) $backup $(echo "`date +%s` + 3600 * 24 * 7" | bc))

    kubectl exec ${vault_configs[ss_name]}-0 -- wget "$backup_url" -O /home/vault/vault_backup.snap
    kubectl exec ${vault_configs[ss_name]}-0 -- vault login $(jq -r ".root_token" vault.json) > /dev/null
    echo -e "${GREEN}***** Restoring Vault... *****${RESET}"
    kubectl exec ${vault_configs[ss_name]}-0 -- vault operator raft snapshot restore -force /home/vault/vault_backup.snap
    sleep 10

    echo -e "${GREEN}***** Restarting Vault... *****${RESET}"
    kubectl scale statefulsets ${vault_configs[ss_name]} --replicas=0
    kubectl scale statefulsets ${vault_configs[ss_name]} --replicas=${vault_configs[replicas]}

    sleep 10
    pod_downtime

    for (( i=0; i<${vault_configs[replicas]}; i++ )) ;
    do
      unseal_node ${vault_configs[ss_name]}-$i
    done
    break
  else
    echo -e "${RED}***** Invalid selection. Please try again. *****${RESET}"
  fi
done
