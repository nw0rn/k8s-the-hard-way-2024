#!/bin/bash
remoteUser="adminuser" # compatible with Azure VMs - will not work for other cloud providers
controlPlane="xxx.xxx.xxx" #add your control plane ip here!
workerNodes=("xxx.xxx.xxx" "xxx.xxx.xxx") #add your worker node ips here!

hosts=("${controlPlane}" "${workerNodes[@]}")
remoteDir="/etc/kubernetes/pki"

for remoteHost in "${hosts[@]}"; do 
    ssh -i /root/.ssh/id_rsa_azure_vm ${remoteUser}@${remoteHost}  << EOF
        sudo mkdir -p ${remoteDir}
EOF
done

# Workaround because adminuser has no permissions for /etc
copy_with_sudo() {
    local filePath=$1
    local remoteFilePath=$2
    local remoteHost=$3
    
    scp -i /root/.ssh/id_rsa_azure_vm "${filePath}" "${remoteUser}@${remoteHost}:/tmp/$(basename "${filePath}")"
    ssh -i /root/.ssh/id_rsa_azure_vm ${remoteUser}@${remoteHost} << EOF
        sudo mv /tmp/$(basename "${filePath}") ${remoteDir}/
        sudo chown root:root ${remoteDir}/$(basename "${filePath}")
        sudo chmod 644 ${remoteDir}/$(basename "${filePath}")
EOF
}

_copy_to_k8s_paths() {
    local certName=$1
    local remoteHost=$2

    read -a remoteHostArray <<< "$remoteHost"

    for host in "${remoteHostArray[@]}"; do
        echo "Copying files to host: ${host}"
        case "${certName}" in
            "kubernetes")
                copy_with_sudo "kubernetes/ca.crt" "${remoteDir}/kubernetes-ca.crt" "${host}"
                copy_with_sudo "kubernetes/ca.key" "${remoteDir}/kubernetes-ca.key" "${host}"
                ;;
            "kube-apiserver")
                copy_with_sudo "kube-apiserver/kube-apiserver.crt" "${remoteDir}/kube-apiserver.crt" "${host}"
                copy_with_sudo "kube-apiserver/kube-apiserver.key" "${remoteDir}/kube-apiserver.key" "${host}"
                ;;
            "kube-apiserver-kubelet-client")
                copy_with_sudo "kube-apiserver-kubelet-client/kube-apiserver-kubelet-client.crt" "${remoteDir}/kube-apiserver-kubelet-client.crt" "${host}"
                copy_with_sudo "kube-apiserver-kubelet-client/kube-apiserver-kubelet-client.key" "${remoteDir}/kube-apiserver-kubelet-client.key" "${host}"
                ;;
            "service-account")
                copy_with_sudo "service-account/sa.key" "${remoteDir}/sa.key" "${host}"
                copy_with_sudo "service-account/sa.pub" "${remoteDir}/sa.pub" "${host}"
                ;;
            node-*)
                copy_with_sudo "${certName}/${certName}.crt" "${remoteDir}/${certName}.crt" "${host}"
                copy_with_sudo "${certName}/${certName}.key" "${remoteDir}/${certName}.key" "${host}"
                ;;
            *)
                echo "Unknown certificate name ${certName}. Skipping copy."
                ;;
        esac
    done
}

_gen_ca(){
    local certName=$1
    local remoteHost=$2

    mkdir -p ${certName}
    if [ ! -f ${certName}/openssl.cnf ]; then
        echo "Configuration file ${certName}/openssl.cnf does not exist. Please create one first."
        return 1
    fi

    if [ -f ${certName}/ca.crt ] && [ -f ${certName}/ca.key ]; then
        echo "Certificate files already exist. Skipping creation."
        return 0
    fi

    mkdir -p ${certName}/newcerts
    touch ${certName}/index.txt
    openssl rand -hex 16 > ${certName}/serial
    openssl genrsa -out ${certName}/ca.key 2048

    if [ ${certName} == "root" ]; then
        openssl req -x509 -new -sha512 -noenc -key ${certName}/ca.key \
                -days 3650 -config ${certName}/openssl.cnf \
                -out ${certName}/ca.crt
        return 0     
    fi

    openssl req -new -sha256 -config ${certName}/openssl.cnf \
        -key ${certName}/ca.key \
        -out ${certName}/csr

    yes | openssl ca -config root/openssl.cnf -extensions v3_intermediate_ca \
        -days 3650 -notext -md sha256 \
        -in ${certName}/csr \
        -out ${certName}/ca.crt

    openssl verify -CAfile root/ca.crt \
        ${certName}/ca.crt
    if [ $? -eq 0 ]; then
        echo -e "\033[1;32mVerification of ${certName}/ca.crt succeeded.\033[0m"
    else
        echo -e "\033[1;31mVerification of ${certName}/ca.crt failed!\033[0m"
        return 1
    fi

    _copy_to_k8s_paths "${certName}" ${remoteHost}

    if [ ${certName} != "root" ]; then 
        cat root/ca.crt ${certName}/ca.crt > ${certName}/ca-chain.crt
        for h in ${hosts[@]}; do
            echo "copying to h ${h}" 
            copy_with_sudo "${certName}/ca-chain.crt" "${remoteDir}/${certName}-ca-chain.crt" "${h}"
        done
    fi

}

_gen_cert(){
    local certName=$1
    local ca=$2
    local remoteHost=$3
    mkdir -p ${certName}
    openssl genrsa -out ${certName}/${certName}.key 2048
    openssl req -config ${ca}/openssl.cnf \
      -section ${certName} \
      -key ${certName}/${certName}.key \
      -new -sha256 -out ${certName}/csr
    
    yes | openssl ca -config ${ca}/openssl.cnf \
        -extensions ${certName}_extensions \
        -days 375 -notext -md sha256 \
        -in ${certName}/csr \
        -out ${certName}/${certName}.crt

    openssl x509 -noout -text \
        -in ${certName}/${certName}.crt

    openssl verify -CAfile ${ca}/ca-chain.crt \
        ${certName}/${certName}.crt
    if [ $? -eq 0 ]; then
        echo -e "\033[1;32mVerification of ${certName}/${certName}.crt succeeded.\033[0m"
    else
        echo -e "\033[1;31mVerification of ${certName}/${certName}.crt failed!\033[0m"
        return 1
    fi
    _copy_to_k8s_paths "${certName}" ${remoteHost}
}

_clean_up(){
    dir=$1

    echo "01" > "$dir/serial"
    echo "Recreated $dir/serial with default value 01."

    > "$dir/index.txt"
    echo "Recreated $dir/index.txt as an empty file."

    rm -f "$dir/index.txt.old" "$dir/serial.old"
    echo "Removed old serial and index.txt files in $dir."

    find . -type f -name "*.pem" -exec rm -f {} +
    find . -type f -name "*.key" -exec rm -f {} +
    find . -type f -name "*.crt" -exec rm -f {} +
    find . -type f -name "*.csr" -exec rm -f {} +
}

find . -type f \( -name "serial" -o -name "index.txt" \) -print0 | \
while IFS= read -r -d '' file; do
    dir=$(dirname "$file")
    _clean_up "$dir"
done

# CAs
_gen_ca root "" # We don't want to copy the root CA
_gen_ca kubernetes "${hosts[*]}"  

# Control Plane
_gen_cert kube-apiserver kubernetes ${controlPlane}
_gen_cert kube-apiserver-kubelet-client kubernetes ${controlPlane}
_gen_cert controller-manager kubernetes ${controlPlane}
_gen_cert scheduler kubernetes ${controlPlane}

mkdir -p service-account
openssl genpkey -algorithm RSA -out service-account/sa.key -pkeyopt rsa_keygen_bits:2048
openssl rsa -in service-account/sa.key -pubout -out service-account/sa.pub
_copy_to_k8s_paths "service-account" "" ${controlPlane}

# Worker Nodes
for i in "${!workerNodes[@]}"; do 
    host="${workerNodes[$i]}"
    _gen_cert "node-$((i+1))" kubernetes "$host"
done

# Kubeconfigs
_gen_cert admin kubernetes

for i in admin node-1 node-2 controller-manager scheduler; do 
    rm -f ${i}.conf
    KUBECONFIG=${i}.conf kubectl config set-cluster default-cluster --server=https://${controlPlane}:6443 --certificate-authority kubernetes/ca-chain.crt --embed-certs
    case "${i}" in 
        "admin")
            export CREDENTIAL_NAME="default-admin"
        ;;
        "node-1")
            export CREDENTIAL_NAME="system:node:worker-node-1"
        ;;
        "node-2")
            export CREDENTIAL_NAME="system:node:worker-node-2"
        ;;
        "controller-manager")
            export CREDENTIAL_NAME="default-controller-manager"
        ;;
        "scheduler")
            export CREDENTIAL_NAME="default-scheduler"
        ;;
    esac
    KUBECONFIG=${i}.conf kubectl config set-credentials ${CREDENTIAL_NAME} --client-key ${i}/${i}.key --client-certificate ${i}/${i}.crt --embed-certs
    KUBECONFIG=${i}.conf kubectl config set-context default-system --cluster default-cluster --user ${CREDENTIAL_NAME}
    KUBECONFIG=${i}.conf kubectl config use-context default-system
done

export remoteDir="/etc/kubernetes"
# Control Plane Kubeconfigs
copy_with_sudo "controller-manager.conf" "${remoteDir}/controller-manager.conf" "${controlPlane}"
copy_with_sudo "scheduler.conf" "${remoteDir}/scheduler.conf" "${controlPlane}"

# Worker Nodes Kubeconfigs
for i in "${!workerNodes[@]}"; do 
    host="${workerNodes[$i]}"
    copy_with_sudo "node-$((i+1)).conf" "${remoteDir}/node-$((i+1)).conf" "$host"
done

# Data encryption at REST on Control Plane
export remoteDir="/etc/kubernetes/pki"
export ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
cat > encryption-config.yaml << EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF
copy_with_sudo "encryption-config.yaml" "${remoteDir}/encryption-config.yaml" "${controlPlane}"