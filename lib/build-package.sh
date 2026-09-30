# shellcheck shell=bash

function make_binary() {
    h2 "make binary"
    if [ ! -d ${pkg_path}/bin ]; then mkdir -p ${pkg_path}/bin; fi

    if [ ! -f ${pkg_path}/bin/cfssl ]; then
        cp ${download_path}/${cfssl_file} ${pkg_path}/bin/cfssl && success "make cfssl"
    else
        note "binary cfssl exists"
    fi

    if [ ! -f ${pkg_path}/bin/cfssljson ]; then
        cp ${download_path}/${cfssljson_file} ${pkg_path}/bin/cfssljson && success "make cfssljson"
    else
        note "binary cfssljson exists"
    fi

    if [ ! -f ${pkg_path}/bin/etcd ]; then
        tar xf ${download_path}/${etcd_file} -C ${pkg_path}/bin --strip-components=1 etcd-v${etcd_version}-linux-${arch_name}/etcd && success "make etcd"
    else
        note "binary etcd exists"
    fi

    if [ ! -f ${pkg_path}/bin/etcdctl ]; then
        tar xf ${download_path}/${etcd_file} -C ${pkg_path}/bin --strip-components=1 etcd-v${etcd_version}-linux-${arch_name}/etcdctl && success "make etcdctl"
    else
        note "binary etcdctl exists"
    fi

    if [ ! -f ${pkg_path}/bin/kube-apiserver ]; then
        tar xf ${download_path}/${kubernetes_file} -C ${pkg_path}/bin --strip-components=3 kubernetes/server/bin/kube-apiserver && success "make kube-apiserver"
    else
        note "binary kube-apiserver exists"
    fi

    if [ ! -f ${pkg_path}/bin/kube-controller-manager ]; then
        tar xf ${download_path}/${kubernetes_file} -C ${pkg_path}/bin --strip-components=3 kubernetes/server/bin/kube-controller-manager && success "make kube-controller-manager"
    else
        note "binary kube-controller-manager exists"
    fi

    if [ ! -f ${pkg_path}/bin/kube-scheduler ]; then
        tar xf ${download_path}/${kubernetes_file} -C ${pkg_path}/bin --strip-components=3 kubernetes/server/bin/kube-scheduler && success "make kube-scheduler"
    else
        note "binary kube-scheduler exists"
    fi

    if [ ! -f ${pkg_path}/bin/kubectl ]; then
        tar xf ${download_path}/${kubernetes_file} -C ${pkg_path}/bin --strip-components=3 kubernetes/server/bin/kubectl && success "make kubectl"
    else
        note "binary kubectl exists"
    fi

    if [ ! -f ${pkg_path}/bin/kubelet ]; then
        tar xf ${download_path}/${kubernetes_file} -C ${pkg_path}/bin --strip-components=3 kubernetes/server/bin/kubelet && success "make kubelet"
    else
        note "binary kubelet exists"
    fi

    if [ ! -f ${pkg_path}/bin/kube-proxy ]; then
        tar xf ${download_path}/${kubernetes_file} -C ${pkg_path}/bin --strip-components=3 kubernetes/server/bin/kube-proxy && success "make kube-proxy"
    else
        note "binary kube-proxy exists"
    fi

    if [ ! -f ${pkg_path}/bin/k9s ]; then
        tar xf ${download_path}/${k9s_file} -C ${pkg_path}/bin k9s && success "make k9s"
    else
        note "binary k9s exists"
    fi
}

function make_yaml() {
    h2 "make yaml"
    if [ ! -d ${pkg_path}/yaml ]; then mkdir -p ${pkg_path}/yaml; fi

    if [ ! -f ${pkg_path}/yaml/${coredns_file} ]; then
        sed -e 's/__DNS__SERVER__/10.96.0.10/g' \
            -e 's/__DNS__DOMAIN__/cluster.local/g' \
            -e 's/__DNS__MEMORY__LIMIT__/200Mi/g' \
            -e 's#image: registry.k8s.io/coredns#image: Placeholder_registry/k8s#g' \
            ${download_path}/${coredns_file}.base >${pkg_path}/yaml/${coredns_file} && success "make ${coredns_file}"
    else
        note "yaml ${coredns_file} exists"
    fi

    if [ ! -f ${pkg_path}/yaml/${localpath_file} ]; then
        sed -e 's#image: rancher/#image: Placeholder_registry/k8s/#g' \
            -e "s#/opt/local-path-provisioner#Placeholder_local_path#g" \
            -e 's#image: busybox#image: Placeholder_registry/k8s/busybox#g' \
            -e '/provisioner: rancher.io/i \  annotations:\n\    defaultVolumeType: local' \
            ${download_path}/${localpath_file} >${pkg_path}/yaml/${localpath_file} && success "make ${localpath_file}"
    else
        note "yaml ${localpath_file} exists"
    fi

    if [ ! -f ${pkg_path}/yaml/${metrics_file} ]; then
        sed -e 's#image: registry.k8s.io/metrics-server#image: Placeholder_registry/k8s#g' \
            -e '/- --metric-resolution=15s/a\        - --kubelet-insecure-tls' \
            ${download_path}/${metrics_file} >${pkg_path}/yaml/${metrics_file} && success "make ${metrics_file}"
    else
        note "yaml ${metrics_file} exists"
    fi

    if [ ! -f ${pkg_path}/yaml/${calico_file} ]; then
        sed -e 's#image: quay.io/calico#image: Placeholder_registry/k8s#g' \
            -e 's/# - name: CALICO_IPV4POOL_CIDR/- name: CALICO_IPV4POOL_CIDR/' \
            -e 's@#   value: \"192.168.0.0/16\"@  value: \"10.244.0.0\/16\"@' \
            -e '/value: "autodetect"/a\            - name: IP_AUTODETECTION_METHOD\n              value: "kubernetes-internal-ip"' \
            ${download_path}/${calico_file} >${pkg_path}/yaml/${calico_file} && success "make ${calico_file}"

        # sed 匹配失败不会报错(上游 YAML 结构变更时静默跳过)，断言避免产出缺配置的离线包
        if ! grep -q 'IP_AUTODETECTION_METHOD' ${pkg_path}/yaml/${calico_file}; then
            rm -f ${pkg_path}/yaml/${calico_file}
            error "make ${calico_file}: IP_AUTODETECTION_METHOD not inserted, check upstream yaml"
        fi
        if ! grep -q 'Placeholder_registry' ${pkg_path}/yaml/${calico_file}; then
            rm -f ${pkg_path}/yaml/${calico_file}
            error "make ${calico_file}: Placeholder_registry not found, image rewrite failed"
        fi
    else
        note "yaml ${calico_file} exists"
    fi
}

function make_tgz() {
    h2 "make tgz"
    if [ ! -d ${pkg_path}/tgz ]; then mkdir -p ${pkg_path}/tgz; fi

    if [ ! -f ${pkg_path}/tgz/${nerdctl_file} ]; then
        cp ${download_path}/${nerdctl_file} ${pkg_path}/tgz/${nerdctl_file} && success "make nerdctl containerd"
    else
        note "pkg ${nerdctl_file} exists"
    fi
}

function make_config() {
    h2 "make config"

    # 安装包内固化目标架构，避免部署时架构不一致
    if sed -e "s#^arch=.*#arch=${arch}#" ${run_path}/config.ini >${build_path}/config.ini; then
        success "make config.ini for ${arch}"
    else
        error "make config.ini failed"
    fi
}

function make_target() {
    note "make target"
    if [ ! -d ${target_path} ]; then mkdir -p ${target_path}; fi

    target_name=${target_path}/kubernetes-v${kubernetes_version}-$(date +%Y%m%d)-${arch_name}.tgz

    if [ -d ${pkg_path} ]; then
        if tar --transform='s,^,k8s-deploy/,' -zcf ${target_name} \
            -C ${run_path} deploy.sh uninstall.sh README.md lib \
            -C ${build_path} config.ini pkg; then
            success "make target ${target_name}"
        else
            error "make target failed"
        fi
    else
        error "${pkg_path} not found!"
    fi
}
