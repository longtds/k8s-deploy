# shellcheck shell=bash

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
    # 用 --no-headers 避免匹配表头 "NAMESPACE" 导致死循环; 仅在仍有 Pod 行时继续等待
    while [ -n "$(kubectl get po -A --no-headers 2>/dev/null)" ]; do
        kubectl get po -A
        sleep 5
        retry_count=$((retry_count + 1))
        if [ ${retry_count} -ge ${max_retry} ]; then
            # 优雅删除超时: kubelet 失联时 Pod 会卡在 Terminating, 强制删除打破 finalizer
            kubectl delete pod --all --all-namespaces --force --grace-period=0 2>/dev/null
            kubectl delete pvc --all --all-namespaces 2>/dev/null
            kubectl delete pv --all --all-namespaces 2>/dev/null
            kubectl delete sc --all --all-namespaces 2>/dev/null
            # calico 等 CRD 自带 finalizer, apiserver 下线后无法完成, 先清空 finalizer 再删除
            kubectl patch crd --all -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
            kubectl delete crd --all --all-namespaces 2>/dev/null
            # 宽限一轮后仍有残留则跳出, 防止卸载死循环
            sleep 5
            if [ -n "$(kubectl get po -A --no-headers 2>/dev/null)" ]; then
                warn "some pods still exist after force delete, skip pod cleanup"
                break
            fi
        fi
    done
}

function delete_service() {
    args=($@)
    num=$#

    if remote_exec_soft ${master_node[0]} "if ${bin_path}/nerdctl ps | grep registry; then ${bin_path}/nerdctl rm -f registry; fi"; then
        success "removed registry on ${master_node[0]}"
    fi

    command1="rm ${systemd_path}/{kubelet.service,kube-proxy.service} -rf
rm /usr/local/lib/systemd/system/{containerd.service,buildkit.service,stargz-snapshotter.service} -rf
systemctl daemon-reload"

    for ((i = 0; i < num; i++)); do
        if remote_exec_soft ${args[${i}]} "if ${bin_path}/nerdctl ps | grep apiproxy; then ${bin_path}/nerdctl rm -f apiproxy; fi"; then
            success "removed apiproxy on ${args[${i}]}"
        fi

        if remote_exec_soft ${args[${i}]} "systemctl stop kubelet"; then
            success "stoped kubelet on ${args[${i}]}"
        fi

        if remote_exec_soft ${args[${i}]} "systemctl stop containerd"; then
            success "stoped containerd on ${args[${i}]}"
        fi

        if remote_exec_soft ${args[${i}]} "${command1}"; then
            success "delete services on ${args[${i}]}"
        fi
    done

    command2="rm ${systemd_path}/{kube-apiserver.service,kube-controller-manager.service,kube-scheduler.service,etcd.service} -rf
systemctl daemon-reload"

    for i in "${master_node[@]}"; do
        if remote_exec_soft ${i} "systemctl stop kube-scheduler"; then
            success "stoped kube-scheduler on ${i}"
        fi

        if remote_exec_soft ${i} "systemctl stop kube-controller-manager"; then
            success "stoped kube-controller-manager on ${i}"
        fi

        if remote_exec_soft ${i} "systemctl stop kube-apiserver"; then
            success "stoped kube-apiserver on ${i}"
        fi

        if remote_exec_soft ${i} "systemctl stop etcd"; then
            success "stoped etcd on ${i}"
        fi

        if remote_exec_soft ${i} "rm ~/.kube -rf"; then
            success "deleted kubeconfig on ${i}"
        fi

        if remote_exec_soft ${i} "${command2}"; then
            success "delete services on ${i}"
        fi
    done
}

function delete_config() {
    args=($@)
    num=$#

    command="rm ${conf_path} -rf
rm /etc/{containerd,cni,crictl.yaml} -rf
rm /etc/sysctl.d/kubernetes.conf -rf
rm /etc/modules-load.d/kubernetes.conf -rf"
    for ((i = 0; i < num; i++)); do
        if remote_exec_soft ${args[${i}]} "${command}"; then
            success "deleted configs on ${args[${i}]}"
        fi
    done
}

function delete_bin() {
    args=($@)
    num=$#

    command="rm /usr/local/bin/{build*,bypass*,containerd*,ctd*,ctr*,fuse*,gomod*,nerdctl*,rootless*,runc,slirp4*,stargz*,tini} -rf
rm /opt/{cni,containerd} -rf
rm ${bin_path}/{kube-apiserver,kube-controller-manager,kube-scheduler,kubelet,kube-proxy,kubectl,k9s,cfssl,cfssljson,etcd,etcdctl} -rf"
    for ((i = 0; i < num; i++)); do
        if remote_exec_soft ${args[${i}]} "${command}"; then
            success "deleted bin files on ${args[${i}]}"
        fi
    done
}

function kill_process() {
    args=($@)
    num=$#

    # 精确匹配本工具部署的二进制全路径, 避免 `ps | grep kube` 误杀同名无关进程或 grep 自身
    # pkill 无匹配返回 1, 整体用 || true 容忍
    command="for p in \
${bin_path}/kube-apiserver ${bin_path}/kube-controller-manager ${bin_path}/kube-scheduler \
${bin_path}/kubelet ${bin_path}/kube-proxy ${bin_path}/etcd ${bin_path}/etcdctl ${bin_path}/cfssl; do
    pkill -9 -f \"^\${p}\" 2>/dev/null || true
done
for p in /usr/local/bin/containerd /usr/local/bin/containerd-shim /usr/local/bin/nerdctl; do
    pkill -9 -f \"^\${p}\" 2>/dev/null || true
done
true"
    for ((i = 0; i < num; i++)); do
        if remote_exec_soft ${args[${i}]} "${command}"; then
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
        if remote_exec_soft ${args[${i}]} "${command}"; then
            success "umounted paths on ${args[${i}]}"
        fi
    done
}

function delete_data() {
    args=($@)
    num=$#

    for ((i = 0; i < num; i++)); do
        if remote_exec_soft ${args[${i}]} "rm ${conf_path} -rf"; then
            success "deleted cfg_path on ${args[${i}]}"
        fi

        if remote_exec_soft ${args[${i}]} "rm ${etcd_data_path} -rf"; then
            success "deleted etcd_data_path on ${args[${i}]}"
        fi

        if remote_exec_soft ${args[${i}]} "rm ${registry_data_path} -rf"; then
            success "deleted registry_path on ${args[${i}]}"
        fi

        if remote_exec_soft ${args[${i}]} "rm /var/lib/cni -rf"; then
            success "deleted cni data on ${args[${i}]}"
        fi

        if remote_exec_soft ${args[${i}]} "rm /var/lib/{containerd,nerdctl} -rf"; then
            success "deleted containerd data on ${args[${i}]}"
        fi

        if remote_exec_soft ${args[${i}]} "rm /var/lib/kubelet -rf"; then
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

