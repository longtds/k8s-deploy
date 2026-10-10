# shellcheck shell=bash

function install_cni_plugin() {
    if sed -e "s#Placeholder_registry#${registry}#g" \
        ${pkg_path}/yaml/${calico_file} | ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig apply -f -; then
        success "calico installed"
    fi

    # 最长等待 15 分钟(90 x 10s), 超时带节点状态输出中止, 不再无限挂起
    wait_until "all ${#node_ip[@]} k8s nodes ready" 90 10 bash -c "
        [ \"\$(${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig get node --no-headers | awk '\$2 ~ /^Ready/ {count++} END {print count+0}')\" -eq '${#node_ip[@]}' ]
    " || { ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig get node; error "nodes not all ready"; }
    success "all k8s nodes are ready"
}

function install_coredns() {
    if sed -e "s#Placeholder_registry#${registry}#g" \
        ${pkg_path}/yaml/${coredns_file} | ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig apply -f -; then
        success "coredns installed"
    fi
}

function install_metrics() {
    if sed -e "s#Placeholder_registry#${registry}#g" \
        ${pkg_path}/yaml/${metrics_file} | ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig apply -f -; then
        success "metrics-server installed"
    fi
}

function install_localpath() {
    if sed -e "s#Placeholder_registry#${registry}#g" \
        -e "s#Placeholder_local_path#${data_path}#g" \
        ${pkg_path}/yaml/${localpath_file} | ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig apply -f -; then
        success "local-path-provisioner installed"
    fi
}

