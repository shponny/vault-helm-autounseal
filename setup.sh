#!/bin/bash

GREEN='\033[0;32m'
RESET='\033[0m'
# Add Hashicorp Helm Repository
helm repo add hashicorp https://helm.releases.hashicorp.com
echo -e "${GREEN}----- 1. Adding Hashicorp Helm Repository -----${RESET}"
# Verify if it has been added
helm repo list | grep hashicorp &> /dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}***** Hashicorp Helm Repository is successfully added. *****${RESET}"
else
    echo -e "${GREEN}***** Failed to add Hashicorp Helm Repository. *****${RESET}"
    exit 1
fi

vault_values="vault"

declare -A vault_configs

# Get the list of contexts from the kubeconfig
contexts=$(kubectl config get-contexts -o name)
contextsforselect=$contexts" New-Context"
clusters=($(kubectl config get-clusters | tail -n +2))
users=($(kubectl config get-users | tail -n +2))

select context in $contextsforselect; do
  if [[ -n $context ]]; then
    echo "You selected: $context"
    if [ "$context" = "${contextsforselect##* }" ]; then
      echo "Creating the context..."
      echo "Please select the cluster:"
      select selected_cluster in "${clusters[@]}"; do
        if [[ -n "$selected_cluster" ]]; then
          echo "Selected cluster: $selected_cluster"
          break
        else
          echo "Invalid selection. Please try again."
        fi
      done
      
      echo "Please select the user:"
      select selected_user in "${users[@]}"; do
        if [[ -n "$selected_user" ]]; then
          echo "Selected cluster: $selected_user"
          break
        else
          echo "Invalid selection. Please try again."
        fi
      done

      read -p "Enter the context name: " new_context

      kubectl config set-context "$new_context" --cluster="$selected_cluster" --user="$selected_user"
      if [ $? -eq 0 ]; then
        echo "Context '$new_context' created successfully."
      else
        echo "Failed to create context."
        exit 1
      fi

      kubectl config use-context "$new_context"
      if [ $? -ne 0 ]; then
        echo "Failed to switch to context '$new_context'."
        exit 1
      fi
    else
      kubectl config use-context $context
      if [ $? -ne 0 ]; then
        echo "Failed to switch to context '$context'."
        exit 1
      fi
    fi
    if kubectl get pods > /dev/null 2>&1; then
      echo "Credentials are valid."
    else
      echo "Invalid credentials or insufficient permissions. Provide new credentials with kubectl or via the ~/.kube/config"
      exit 1
    fi

    namespace=$(kubectl config view --minify --output 'jsonpath={..namespace}')

    while true; do
      read -p "Do you want to change the namespace from $namespace? (y/n) " yn
      case $yn in
        [yY] ) echo "Ok, changing namespace..."
          read -p "Please enter a valid namespace: " namespace
        [nN] ) echo "Using $namespace..."
                ;;
        * ) echo "Invalid response. Please enter y or n.";;
      esac
      # Exit the loop after a valid choice (y or n)
      break
    done
    break

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
    done
    break
  else
    echo "Invalid selection"
  fi
done

vault_configs[values]=$vault_values".yaml"
vault_configs[release_name]=$(yq -r '.releaseName' ${vault_configs[values]})


while true; do
  read -p "Have you already installed Vault Helm Release(s)? (y/n) " yn
  case $yn in
    [yY] ) echo "Ok, skipping installation..."
      vault_installed_bool=true
            ;;
    [nN] ) echo "Installing Vault..."
      vault_installed_bool=false
            ;;
    * ) echo "Invalid response. Please enter y or n.";;
  esac
  # Exit the loop after a valid choice (y or n)
  break
done


if ! $vault_installed_bool ; then
  # Creating a Kubernetes TLS Secret
  if [[ -f "tls.key" && -f "tls.crt" ]]; then
    echo -e "${GREEN}----- 1.1. Creating a Kubernetes TLS Secret in the $namespace namespace  -----${RESET}"
    kubectl create secret tls vault-cert --cert=tls.crt --key=tls.key && echo -e "${GREEN}***** OpenShift TLS Secret for Vault has been created. *****${RESET}"
  fi

  if [ $(yq -r '.server.standalone.enabled' ${vault_configs[values]}) = true ];
  then
    vault_configs[replicas]=1
  else
    vault_configs[replicas]=$(yq -r '.server.ha.replicas' ${vault_configs[values]})
  fi

  echo -e "${GREEN}----- 2. Installing Helm Release...  -----${RESET}"
    # Create two Helm releases with the names that were provided by user before in the namespace that is in the current-context
  helm upgrade -i ${vault_configs[release_name]} hashicorp/vault -n $namespace -f ${vault_configs[values]} && \
  echo -e "${GREEN}***** Hashicorp Vault Helm Release named ${vault_configs[release_name]} has been created in the namespace $namespace. *****${RESET}" && \
  vault_configs[ss_name]=$(kubectl get statefulset -l app.kubernetes.io/instance=${vault_configs[release_name]} -o="jsonpath={.items[0].metadata.name}")

  # Asking for key shares and thresholds for each cluster
  echo -e "${GREEN}----- 3. Initiating cluster members and HA -----${RESET}"
  echo -e "${GREEN}***** Configuring ${vault_configs[release_name]}... *****${RESET}"

  read -p "Enter the number of key shares for Vault Cluster ${vault_configs[release_name]}: " key_shares
  read -p "Enter the number of key threshold for Vault Cluster ${vault_configs[release_name]}: " key_threshold

  while ((key_threshold > key_shares))
  do
    echo "The key threshold should be equal or less than the number of key shares. Please enter again."
    read -p "Enter the number of key threshold for Vault Cluster ${vault_configs[release_name]}: " key_threshold
  done

  vault_configs[key_shares]=$key_shares
  vault_configs[key_threshold]=$key_threshold

  echo "${vault_configs[release_name]} will be configured with ${vault_configs[key_shares]} key shares and a key threshold of ${vault_configs[key_threshold]}."
  
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

  echo -e "${GREEN}***** Initiating the first pod (${vault_configs[ss_name]}-0). Keys and root token will be available in the $vault_values.json file... *****${RESET}"
  initout=$(kubectl exec ${vault_configs[ss_name]}-0 -- vault operator init -key-shares=${vault_configs[key_shares]} -key-threshold=${vault_configs[key_threshold]} -format=json) && echo $initout > $vault_values.json

  # Unsealing replicas
  for (( i=0; i<${vault_configs[replicas]}; i++ )) ;
  do
    j=0
    PROGRESS=99
    sleep 7
    echo -e "${GREEN}***** Unsealing ${vault_configs[ss_name]}-$i... *****${RESET}"
    until [ $PROGRESS -eq 0 ]
    do
      KEY=$(jq --arg j $j -r ".unseal_keys_hex[$j]" $vault_values.json)
      # Unsealing!
      PROGRESS=$(kubectl exec ${vault_configs[ss_name]}-$i -- vault operator unseal -format=json $KEY | jq -j '.progress')
      j=$((j+1))
    done
  done

  # List peers for cluster
  echo $(kubectl exec ${vault_configs[ss_name]}-0 -- vault login $(jq -r ".root_token" $vault_values.json)) > /dev/null
  kubectl exec ${vault_configs[ss_name]}-0 -- vault operator raft list-peers
  kubectl exec ${vault_configs[ss_name]}-0 -- rm /home/vault/.vault-token
fi


while true; do
  read -p "Do you need to set up automatic backups for your cluster? (y/n) " yn
  case $yn in
    [yY] ) echo "Ok, setting up backup cronjobs..."

      read -p "Enter the S3 server address: (example - s3.loc.icdc.io)" s3_endpoint
      read -p "Enter the S3 Access Key ID: " s3_access_key_id
      read -p "Enter the S3 Secret Access Key: " s3_secret_access_key
      s3_bucket=""
      kubectl delete secret vaults-snapshot-s3 --ignore-not-found
      kubectl create secret generic vaults-snapshot-s3 --from-literal=AWS_ACCESS_KEY_ID=$s3_access_key_id --from-literal=AWS_SECRET_ACCESS_KEY=$s3_secret_access_key --from-literal=AWS_ENDPOINT="https://$s3_endpoint/"

      if [ $(yq -r '.server.ha.enabled' "${vault_configs[values]}") = true ];
      then
        echo "Authenticating on the ${vault_configs[release_name]} (main) - leader..."
        vault_configs[internal_fqdn]=$(echo $(kubectl get svc -lapp.kubernetes.io/instance=${vault_configs[release_name]},vault-active=true -o='jsonpath={.items[0].metadata.name}')"."$namespace".svc.cluster.local")
        vault_main_active_pod=$(kubectl get pods -lapp.kubernetes.io/instance=${vault_configs[release_name]},vault-active=true -o='jsonpath={.items[0].metadata.name}')
      else
        echo "Authenticating on the ${vault_configs[release_name]} (main) - the only pod..."
        vault_configs[internal_fqdn]=$(echo $(kubectl get svc -lapp.kubernetes.io/instance=${vault_configs[release_name]},'!vault-active' -o='jsonpath={.items[0].metadata.name}')"."$namespace".svc.cluster.local")
        vault_main_active_pod=$(kubectl get pods -lapp.kubernetes.io/instance=${vault_configs[release_name]} -o='jsonpath={.items[0].metadata.name}')
      fi
      read -p "Enter the bucket name for the ${vault_configs[release_name]}: " s3_bucket
      echo $(kubectl exec $vault_main_active_pod -- vault login $(jq -r ".root_token" $vault_values.json)) > /dev/null

      echo -e "${GREEN}***** Activating the AppRole and creating the snapshot-agent (AppRole) for the ${vault_configs[release_name]} cluster... *****${RESET}"
      cat snapshot.hcl | kubectl exec -i $vault_main_active_pod -- vault policy write snapshot -
      kubectl exec $vault_main_active_pod -- vault auth enable approle
      kubectl exec $vault_main_active_pod -- vault write auth/approle/role/snapshot-agent token_ttl=2h token_policies=snapshot
      role_id=$(kubectl exec $vault_main_active_pod -- vault read auth/approle/role/snapshot-agent/role-id -format=json | jq -r .data.role_id)
      secret_id=$(kubectl exec $vault_main_active_pod -- vault write -f auth/approle/role/snapshot-agent/secret-id -format=json | jq -r .data.secret_id)

      echo -e "${GREEN}***** Creating the snapshot-agent Secret (AppRole) for the ${vault_configs[release_name]} cluster... *****${RESET}"
      kubectl delete secret ${vault_configs[release_name]}-snapshot-agent-token --ignore-not-found
      kubectl create secret generic ${vault_configs[release_name]}-snapshot-agent-token --from-literal=VAULT_APPROLE_ROLE_ID=$role_id --from-literal=VAULT_APPROLE_SECRET_ID=$secret_id

      snapshot_fqdn=${vault_configs[internal_fqdn]}

      echo -e "${GREEN}***** Filling up the ${vault_values}_snapshot_cronjob.yaml for the ${vault_configs[release_name]} cluster... *****${RESET}"
      yq -i -Y --arg st_release "${vault_configs[release_name]}" '.metadata.name = $st_release + "-snapshot-cronjob"' ${vault_values}_snapshot_cronjob.yaml
      yq -i -Y --arg st_release "${vault_configs[release_name]}" '.spec.jobTemplate.spec.template.spec.containers[0].envFrom[0].secretRef.name = $st_release + "-snapshot-agent-token"' ${vault_values}_snapshot_cronjob.yaml
      yq -i -Y --arg st_fqdn "$snapshot_fqdn" '.spec.jobTemplate.spec.template.spec.containers[0].env[0].value = "http://" + $st_fqdn + ":8200"' ${vault_values}_snapshot_cronjob.yaml
      yq -i -Y --arg st_bucket "$s3_bucket" '.spec.jobTemplate.spec.template.spec.containers[1].env[0].value = $st_bucket' ${vault_values}_snapshot_cronjob.yaml
      
      echo -e "${GREEN}***** Creating the backup CronJob for the ${vault_configs[release_name]} cluster... *****${RESET}"
      kubectl delete cronjob ${vault_configs[release_name]}-snapshot-cronjob --ignore-not-found
      kubectl apply -f ${vault_values}_snapshot_cronjob.yaml
            ;;
    [nN] ) echo "Skipping."
            ;;
    * ) echo "Invalid response. Please enter y or n.";;
  esac
  # Exit the loop after a valid choice (y or n)
  break
done
