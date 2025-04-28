#!/bin/bash
# shellcheck disable=SC2087,SC2086,SC2206,SC2016,SC1091,SC2154

if [ -f config.ini ]; then
    source config.ini
else
    echo "Configuration file config.ini not found."
    exit 1
fi

set +e
set -o noglob

bold=$(tput bold)
underline=$(tput sgr 0 1)
reset=$(tput sgr0)
red=$(tput setaf 1)
green=$(tput setaf 76)
white=$(tput setaf 7)
tan=$(tput setaf 202)
blue=$(tput setaf 25)

underline() {
    printf "${underline}${bold}%s${reset}\n" "$@"
}
h1() {
    printf "\n${underline}${bold}${blue}%s${reset}\n" "$@"
}
h2() {
    printf "\n${underline}${bold}${white}%s${reset}\n" "$@"
}
debug() {
    printf "${white}%s${reset}\n" "$@"
}
info() {
    printf "${white}➜ %s${reset}\n" "$@"
}
success() {
    printf "$(TZ=UTC-8 date +%Y-%m-%d" "%H:%M:%S) ${green}✔ %s${reset}\n" "$@"
}
error() {
    printf "${red}✖ %s${reset}\n" "$@"
    exit 2
}
warn() {
    printf "${tan}➜ %s${reset}\n" "$@"
}
bold() {
    printf "${bold}%s${reset}\n" "$@"
}
note() {
    printf "\n${underline}${bold}${blue}Note:${reset} ${blue}%s${reset}\n" "$@"
}

set -e

if [ ${#node_ip[@]} -ge 3 ]; then
    master_node=(${node_ip[0]} ${node_ip[1]} ${node_ip[2]})
else
    master_node=(${node_ip[0]})
fi

if [ $1 == "all" ]; then
    allnode_ip=(${node_ip[@]} ${addnode_ip[@]})
else
    allnode_ip=(${node_ip[@]})
fi

function remote_exec() {
    local host=$1
    local cmd=$2
    if ! ssh -p ${ssh_port} root@${host} "${cmd}" >/dev/null 2>&1; then
        error "Execute command failed on ${host}: ${cmd}"
    fi
}

function delete_resource() {
    deployments=$(${bin_path}/kubectl get deploy --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')
    statefulsets=$(${bin_path}/kubectl get sts --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')
    daemonsets=$(${bin_path}/kubectl get ds --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')
    replicasets=$(${bin_path}/kubectl get rs --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')

    if [ -n "$replicasets" ]; then
        for REPLICASET in ${replicasets}; do
            NAMESPACE=$(echo $REPLICASET | cut -d/ -f1)
            NAME=$(echo $REPLICASET | cut -d/ -f2)
            ${bin_path}/kubectl delete replicaset $NAME -n $NAMESPACE
        done
    fi

    if [ -n "$deployments" ]; then
        for DEPLOYMENT in ${deployments}; do
            NAMESPACE=$(echo $DEPLOYMENT | cut -d/ -f1)
            NAME=$(echo $DEPLOYMENT | cut -d/ -f2)
            ${bin_path}/kubectl delete deployment $NAME -n $NAMESPACE
        done
    fi

    if [ -n "$statefulsets" ]; then
        for STATEFULSET in ${statefulsets}; do
            NAMESPACE=$(echo $STATEFULSET | cut -d/ -f1)
            NAME=$(echo $STATEFULSET | cut -d/ -f2)
            ${bin_path}/kubectl delete statefulset $NAME -n $NAMESPACE
        done
    fi

    if [ -n "$daemonsets" ]; then
        for DAEMONSET in ${daemonsets}; do
            NAMESPACE=$(echo $DAEMONSET | cut -d/ -f1)
            NAME=$(echo $DAEMONSET | cut -d/ -f2)
            ${bin_path}/kubectl delete daemonset $NAME -n $NAMESPACE
        done
    fi

    max_retry=10
    retry_count=0
    while ${bin_path}/kubectl get po -A | grep NAMESPACE; do
        ${bin_path}/kubectl get po -A
        sleep 5
        retry_count=$((retry_count + 1))
        if [ ${retry_count} -ge ${max_retry} ]; then
            ${bin_path}/kubectl delete pod --all --all-namespaces
            ${bin_path}/kubectl delete pvc --all --all-namespaces
            ${bin_path}/kubectl delete pv --all --all-namespaces
            ${bin_path}/kubectl delete sc --all --all-namespaces
            ${bin_path}/kubectl delete crd --all --all-namespaces
        fi
    done
}

function stop_service() {
    args=($@)
    num=$#

    if remote_exec ${master_node[0]} "if ${bin_path}/nerdctl ps | grep registry; then ${bin_path}/nerdctl rm -f registry; fi"; then
        success "remove registry service on ${master_node[0]} successfully"
    fi

    for i in "${master_node[@]}"; do
        if remote_exec ${i} "systemctl stop kube-scheduler"; then
            success "stop kube-scheduler services on ${i} successfully"
        fi

        if remote_exec ${i} "systemctl stop kube-controller-manager"; then
            success "stop kube-controller-manager services on ${i} successfully"
        fi

        if remote_exec ${i} "systemctl stop kube-apiserver"; then
            success "stop kube-apiserver services on ${i} successfully"
        fi

        if remote_exec ${i} "systemctl stop etcd"; then
            success "stop etcd services on ${i} successfully"
        fi
    done

    for ((i = 0; i < num; i++)); do
        if [ ${#node_ip[@]} -le 3 ]; then
            if remote_exec ${args[${i}]} "if ${bin_path}/nerdctl ps | grep apiproxy; then ${bin_path}/nerdctl rm -f apiproxy; fi"; then
                success "remove apiproxy services on ${args[${i}]} successfully"
            fi
        fi

        if ! ${kubeproxyreplacement_enable}; then
            if remote_exec ${args[${i}]} "systemctl stop kube-proxy"; then
                success "stop kube-proxy services on ${args[${i}]} successfully"
            fi
        fi

        if remote_exec ${args[${i}]} "systemctl stop kubelet"; then
            success "stop kubelet services on ${args[${i}]} successfully"
        fi

        if remote_exec ${args[${i}]} "systemctl stop containerd"; then
            success "stop containerd services on ${args[${i}]} successfully"
        fi
    done
}

function delete_service() {
    args=($@)
    num=$#

    command="rm /lib/systemd/system/{kube*,etcd.service} -rf
rm /etc/systemd/system/containerd.service -rf
systemctl daemon-reload"
    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "delete services on ${args[${i}]} successfully"
        fi
    done
}

function delete_config() {
    args=($@)
    num=$#

    command="rm ${cfg_path} -rf
rm /etc/{containerd,cni,crictl.yaml} -rf
rm /etc/sysctl.d/kubernetes.conf -rf
rm /etc/modules-load.d/{kubernetes.conf,ipvs.conf} -rf"
    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "delete configs on ${args[${i}]} successfully"
        fi
    done
}

function delete_bin() {
    args=($@)
    num=$#

    command="rm /usr/local/bin/{containerd*,cri*,ctd*,ctr,nerdctl} -rf
rm ${bin_path} -rf
rm /opt/{cni,containerd} -rf"
    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "delete bin files on ${args[${i}]} successfully"
        fi
    done
}

function kill_process() {
    args=($@)
    num=$#

    command="if ps -e | grep containerd; then ps -e | grep containerd | awk '{print \$1}' | xargs kill -9; fi"
    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "kill containerd-shim process on ${args[${i}]} successfully"
        fi
    done
}

function umount_path() {
    args=($@)
    num=$#

    command="for mount in \$(df | grep kubelet | awk '{print \$6}');do umount \$mount;done
for mount in \$(df | grep containerd | awk '{print \$6}');do umount \$mount;done"
    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "umount paths on ${args[${i}]} successfully"
        fi
    done
}

function delete_data() {
    args=($@)
    num=$#

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "rm ${base_path} -rf"; then
            success "delete kubernetes path on ${args[${i}]} successfully"
        fi
    done

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "rm /var/lib/cni -rf"; then
            success "delete cni data on ${args[${i}]} successfully"
        fi
    done

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "rm /var/lib/{containerd,nerdctl} -rf"; then
            success "delete containerd data on ${args[${i}]} successfully"
        fi
    done

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "rm /var/lib/kubelet -rf"; then
            success "delete kubelet data on ${args[${i}]} successfully"
        fi
    done
}

function delete_local() {
    if [ -d ${run_path}/pki ]; then
        rm ${run_path}/pki -rf && success "delete pki dir successfully"
    fi

    if [ -f ${pkg_path}/${cert_file} ]; then
        rm ${pkg_path:?}/${cert_file} -rf && success "delete cert file successfully"
    fi

    if [ -d ${pkg_path}/cfssl ]; then
        rm ${pkg_path}/{cfssl,cfssljson} -rf && success "delete cfssl bin successfully"
    fi
}

delete_resource
stop_service "${allnode_ip[@]}"
delete_service "${allnode_ip[@]}"
delete_config "${allnode_ip[@]}"
delete_bin "${allnode_ip[@]}"
kill_process "${allnode_ip[@]}"
umount_path "${allnode_ip[@]}"
delete_data "${allnode_ip[@]}"
delete_local
