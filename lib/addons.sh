# shellcheck shell=bash

function install_cni_plugin() {
    if sed -e "s#Placeholder_registry#${registry}#g" \
        ${pkg_path}/yaml/${calico_file} | ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig apply -f -; then
        success "calico installed"
    fi

    until [ "$(${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig get node --no-headers | awk '$2 ~ /^Ready/ {count++} END {print count+0}')" -eq "${#node_ip[@]}" ]; do
        ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig get node || true
        sleep 10
    done
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

