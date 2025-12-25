#!/bin/bash
# shellcheck disable=SC2087,SC2086,SC2206,SC2016,SC1091,SC2154

if [ -f config.ini ]; then
    source config.ini
else
    echo "Configuration file config.ini not found."
    exit 1
fi

if [ -f utils.sh ]; then
    source utils.sh
else
    echo "file utils.sh not found."
    exit 1
fi

set +e

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

export KUBECONFIG=${run_path}/admin.kubeconfig

function delete_resource() {
    deployments=$(kubectl get deploy --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')
    statefulsets=$(kubectl get sts --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')
    daemonsets=$(kubectl get ds --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')
    replicasets=$(kubectl get rs --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')

    if [ -n "$replicasets" ]; then
        for REPLICASET in ${replicasets}; do
            NAMESPACE=$(echo $REPLICASET | cut -d/ -f1)
            NAME=$(echo $REPLICASET | cut -d/ -f2)
            kubectl delete replicaset $NAME -n $NAMESPACE
        done
    fi

    if [ -n "$deployments" ]; then
        for DEPLOYMENT in ${deployments}; do
            NAMESPACE=$(echo $DEPLOYMENT | cut -d/ -f1)
            NAME=$(echo $DEPLOYMENT | cut -d/ -f2)
            kubectl delete deployment $NAME -n $NAMESPACE
        done
    fi

    if [ -n "$statefulsets" ]; then
        for STATEFULSET in ${statefulsets}; do
            NAMESPACE=$(echo $STATEFULSET | cut -d/ -f1)
            NAME=$(echo $STATEFULSET | cut -d/ -f2)
            kubectl delete statefulset $NAME -n $NAMESPACE
        done
    fi

    if [ -n "$daemonsets" ]; then
        for DAEMONSET in ${daemonsets}; do
            NAMESPACE=$(echo $DAEMONSET | cut -d/ -f1)
            NAME=$(echo $DAEMONSET | cut -d/ -f2)
            kubectl delete daemonset $NAME -n $NAMESPACE
        done
    fi

    max_retry=10
    retry_count=0
    while kubectl get po -A | grep NAMESPACE; do
        kubectl get po -A
        sleep 5
        retry_count=$((retry_count + 1))
        if [ ${retry_count} -ge ${max_retry} ]; then
            kubectl delete pod --all --all-namespaces
            kubectl delete pvc --all --all-namespaces
            kubectl delete pv --all --all-namespaces
            kubectl delete sc --all --all-namespaces
            kubectl delete crd --all --all-namespaces
        fi
    done
}

function delete_service() {
    args=($@)
    num=$#

    if remote_exec ${master_node[0]} "if ${install_path}/bin/nerdctl ps | grep registry; then ${install_path}/bin/nerdctl rm -f registry; fi"; then
        success "removed registry on ${master_node[0]}"
    fi

    command1="rm /lib/systemd/system/{kubelet.service,kube-proxy.service} -rf
rm /usr/local/lib/systemd/system/{containerd.service,buildkit.service,stargz-snapshotter.service} -rf
systemctl daemon-reload"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "if ${install_path}/bin/nerdctl ps | grep apiproxy; then ${install_path}/bin/nerdctl rm -f apiproxy; fi"; then
            success "removed apiproxy on ${args[${i}]}"
        fi

        if remote_exec ${args[${i}]} "systemctl stop kubelet"; then
            success "stoped kubelet on ${args[${i}]}"
        fi

        if remote_exec ${args[${i}]} "systemctl stop containerd"; then
            success "stoped containerd on ${args[${i}]}"
        fi

        if remote_exec ${args[${i}]} "${command1}"; then
            success "delete services on ${args[${i}]}"
        fi
    done

    command2="rm /lib/systemd/system/{kube-apiserver.service,kube-controller-manager.service,kube-scheduler.service,etcd.service} -rf
systemctl daemon-reload"

    for i in "${master_node[@]}"; do
        if remote_exec ${i} "systemctl stop kube-scheduler"; then
            success "stoped kube-scheduler on ${i}"
        fi

        if remote_exec ${i} "systemctl stop kube-controller-manager"; then
            success "stoped kube-controller-manager on ${i}"
        fi

        if remote_exec ${i} "systemctl stop kube-apiserver"; then
            success "stoped kube-apiserver on ${i}"
        fi

        if remote_exec ${i} "systemctl stop etcd"; then
            success "stoped etcd on ${i}"
        fi

        if remote_exec ${i} "rm ~/.kube -rf"; then
            success "deleted kubeconfig on ${i}"
        fi

        if remote_exec ${i} "${command2}"; then
            success "delete services on ${i}"
        fi
    done
}

function delete_config() {
    args=($@)
    num=$#

    command="rm ${install_path}/etc -rf
rm /etc/{containerd,cni,crictl.yaml} -rf
rm /etc/sysctl.d/kubernetes.conf -rf
rm /etc/modules-load.d/kubernetes.conf -rf"
    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "deleted configs on ${args[${i}]}"
        fi
    done
}

function delete_bin() {
    args=($@)
    num=$#

    command="rm /usr/local/bin/{build*,bypass*,containerd*,ctd*,ctr*,fuse*,gomod*,nerdctl*,rootless*,runc,slirp4*,stargz*,tini} -rf
rm /opt/{cni,containerd} -rf
rm ${install_path}/bin/{kube-apiserver,kube-controller-manager,kube-scheduler,kubelet,kube-proxy,kubectl,k9s,cfssl,cfssljson,etcd,etcdctl} -rf"
    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "deleted bin files on ${args[${i}]}"
        fi
    done
}

function kill_process() {
    args=($@)
    num=$#

    command="if ps -e | grep containerd; then ps -e | grep containerd | awk '{print \$1}' | xargs kill -9; fi
if ps -e | grep kube; then ps -e | grep kube | awk '{print \$1}' | xargs kill -9; fi"
    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "killed containerd and kube process on ${args[${i}]}"
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
            success "umounted paths on ${args[${i}]}"
        fi
    done
}

function delete_data() {
    args=($@)
    num=$#

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "rm ${install_path}/etc -rf"; then
            success "deleted cfg_path on ${args[${i}]}"
        fi

        if remote_exec ${args[${i}]} "rm ${data_path}/etcd -rf"; then
            success "deleted etcd_data_path on ${args[${i}]}"
        fi

        if remote_exec ${args[${i}]} "rm ${data_path}/registry -rf"; then
            success "deleted registry_path on ${args[${i}]}"
        fi

        if remote_exec ${args[${i}]} "rm /var/lib/cni -rf"; then
            success "deleted cni data on ${args[${i}]}"
        fi

        if remote_exec ${args[${i}]} "rm /var/lib/{containerd,nerdctl} -rf"; then
            success "deleted containerd data on ${args[${i}]}"
        fi

        if remote_exec ${args[${i}]} "rm /var/lib/kubelet -rf"; then
            success "deleted kubelet data on ${args[${i}]}"
        fi
    done
}

function delete_local() {
    if [ -d ${run_path}/pki ]; then
        rm ${run_path}/pki -rf && success "deleted pki dir on localhost"
    fi

    if [ -f ${run_path}/admin.kubeconfig ]; then
        rm ${run_path}/admin.kubeconfig -f && success "deleted kubeconfig on localhost"
    fi

    if [ -f ${run_path}/hosts ]; then
        rm ${run_path}/hosts -f && success "deleted hosts on localhost"
    fi
}

delete_resource
delete_service "${allnode_ip[@]}"
kill_process "${allnode_ip[@]}"
delete_config "${allnode_ip[@]}"
delete_bin "${allnode_ip[@]}"
kill_process "${allnode_ip[@]}"
umount_path "${allnode_ip[@]}"
delete_data "${allnode_ip[@]}"
delete_local
