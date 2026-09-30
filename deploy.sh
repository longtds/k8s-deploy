#!/bin/bash
# shellcheck disable=SC2087,SC2086,SC2206,SC2016,SC1091,SC2154

for f in lib/common.sh config.ini lib/remote.sh lib/preflight.sh lib/system.sh lib/certs.sh \
    lib/distribute.sh lib/control-plane.sh lib/node.sh lib/addons.sh; do
    if [ -f "$f" ]; then
        source "$f"
    else
        echo "file $f not found."
        exit 1
    fi
done

# kube_token 为空(或仍为历史公开默认值)时, 按优先级取用/生成 token 并持久化到 pki/kube_token,
# 后续 install/addnode 复用同一 token(apiserver token.csv 与 kubelet bootstrap kubeconfig 必须一致):
#   config.ini 显式值 > pki/kube_token > 已有 kubelet-bootstrap.kubeconfig 中的 token(兼容旧版本安装的集群) > 随机生成
if [ $# -eq 1 ] && { [ -z "${kube_token}" ] || [ "${kube_token}" == "e3b0c44298fc1c149afbf4c8996fb924" ]; }; then
    if [ -f ${pki_path}/kube_token ]; then
        kube_token=$(cat ${pki_path}/kube_token)
    elif [ -f ${pki_path}/kubelet-bootstrap.kubeconfig ]; then
        kube_token=$(awk '/token:/ {print $2; exit}' ${pki_path}/kubelet-bootstrap.kubeconfig)
    fi
    if [ -z "${kube_token}" ]; then
        mkdir -p ${pki_path}
        kube_token=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    fi
    if ! printf '%s\n' "${kube_token}" >${pki_path}/kube_token; then
        error "save kube_token to ${pki_path}/kube_token failed"
    fi
    chmod 600 ${pki_path}/kube_token
fi

if [ ${#node_ip[@]} -ge 3 ]; then
    master_node=(${node_ip[0]} ${node_ip[1]} ${node_ip[2]})
    apiserver_url=https://127.0.0.1:8443
else
    master_node=(${node_ip[0]})
    apiserver_url=https://${master_node[0]}:6443
fi

node_ip_hostname=(${node_ip[@]} ${node_hostname[@]})
addnode_ip_hostname=(${addnode_ip[@]} ${addnode_hostname[@]})
registry=${node_ip[0]}:5000

if [ $# -eq 0 ]; then
    echo "Usage: ./k8s [command]
  Commands:
    install     Install the Kubernetes cluster.
    addnode     Adding nodes to the existing Kubernetes cluster.
    "
fi

if [ $# -eq 1 ]; then
    if [ $1 == "install" ]; then
        check_pkg
        check_node_pkg "${node_ip[@]}"
        config_certs
        config_system "${node_ip_hostname[@]}"
        sync_hosts "${node_ip[@]}"
        sync_certs "${node_ip[@]}"
        sync_pkg "${node_ip[@]}"
        config_etcd
        config_apiserver
        config_containerd "${node_ip[@]}"
        config_apiproxy "${node_ip[@]}"
        config_controller
        config_scheduler
        config_kubeconfig
        config_kubelet "${node_ip_hostname[@]}"
        config_kubeproxy "${node_ip[@]}"
        config_registry
        install_cni_plugin
        install_coredns
        install_metrics
        install_localpath
    fi

    if [ $1 == "addnode" ]; then
        check_pkg
        check_node_pkg "${addnode_ip[@]}"
        config_system "${addnode_ip_hostname[@]}"
        sync_hosts "${node_ip[@]}"
        sync_certs "${addnode_ip[@]}"
        sync_pkg "${addnode_ip[@]}"
        config_containerd "${addnode_ip[@]}"
        config_apiproxy "${addnode_ip[@]}"
        config_kubelet "${addnode_ip_hostname[@]}"
        config_kubeproxy "${addnode_ip[@]}"
    fi
fi
