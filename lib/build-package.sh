# shellcheck shell=bash

# 单个二进制产物: 文件存在且版本戳匹配才跳过, 版本号变更自动重建
function make_one_bin() {
    local name=$1 cache_key=$2 extractor=$3
    local target=${pkg_path}/bin/${name}
    if [ -f "${target}" ] && cache_valid "bin-${name}" "${target}" "${cache_key}" "${arch_name}"; then
        note "binary ${name} exists"
        return 0
    fi
    if bash -c "${extractor}"; then
        cache_commit "bin-${name}" "${cache_key}" "${arch_name}"
        success "make ${name}"
    else
        error "make ${name} failed"
    fi
}

function make_binary() {
    h2 "make binary"
    if [ ! -d ${pkg_path}/bin ]; then mkdir -p ${pkg_path}/bin; fi

    make_one_bin cfssl "${cfssl_version}" \
        "cp ${download_path}/${cfssl_file} ${pkg_path}/bin/cfssl"
    make_one_bin cfssljson "${cfssl_version}" \
        "cp ${download_path}/${cfssljson_file} ${pkg_path}/bin/cfssljson"
    make_one_bin etcd "${etcd_version}" \
        "tar xf ${download_path}/${etcd_file} -C ${pkg_path}/bin --strip-components=1 etcd-v${etcd_version}-linux-${arch_name}/etcd"
    make_one_bin etcdctl "${etcd_version}" \
        "tar xf ${download_path}/${etcd_file} -C ${pkg_path}/bin --strip-components=1 etcd-v${etcd_version}-linux-${arch_name}/etcdctl"

    local b
    for b in kube-apiserver kube-controller-manager kube-scheduler kubectl kubelet kube-proxy; do
        make_one_bin "${b}" "${kubernetes_version}" \
            "tar xf ${download_path}/${kubernetes_file} -C ${pkg_path}/bin --strip-components=3 kubernetes/server/bin/${b}"
    done

    make_one_bin k9s "${k9s_version}" \
        "tar xf ${download_path}/${k9s_file} -C ${pkg_path}/bin k9s"
}

# yaml 产物通用封装: 版本/网络配置/源文件哈希任一变化即重写, 断言失败则删除产物并中止
function make_one_yaml() {
    local name=$1 src=$2 cache_key=$3 producer=$4 assert=$5
    local target=${pkg_path}/yaml/${name}
    local src_hash
    src_hash=$(sha256sum "${src}" | awk '{print $1}')
    if [ -f "${target}" ] && cache_valid "yaml-${name}" "${target}" "${cache_key}" "${src_hash}"; then
        note "yaml ${name} exists"
        return 0
    fi
    if bash -c "${producer}"; then
        if ! eval "${assert}"; then
            rm -f "${target}"
            error "make ${name}: rewrite assertion failed, check upstream yaml changes"
        fi
        cache_commit "yaml-${name}" "${cache_key}" "${src_hash}"
        success "make ${name}"
    else
        rm -f "${target}"
        error "make ${name} failed"
    fi
}

function make_yaml() {
    h2 "make yaml"
    if [ ! -d ${pkg_path}/yaml ]; then mkdir -p ${pkg_path}/yaml; fi

    make_one_yaml "${coredns_file}" "${download_path}/${coredns_file}.base" \
        "${kubernetes_version}|${cluster_dns}|${cluster_domain}" \
        "sed -e 's/__DNS__SERVER__/${cluster_dns}/g' \
            -e 's/__DNS__DOMAIN__/${cluster_domain}/g' \
            -e 's/__DNS__MEMORY__LIMIT__/200Mi/g' \
            -e 's#image: registry.k8s.io/coredns#image: Placeholder_registry/k8s#g' \
            ${download_path}/${coredns_file}.base >${pkg_path}/yaml/${coredns_file}" \
        "grep -q 'image: Placeholder_registry/k8s/coredns' ${pkg_path}/yaml/${coredns_file} && ! grep -q '__DNS__' ${pkg_path}/yaml/${coredns_file}"

    make_one_yaml "${localpath_file}" "${download_path}/${localpath_file}" \
        "${localpath_version}|${data_path}" \
        "sed -e 's#image: rancher/#image: Placeholder_registry/k8s/#g' \
            -e 's#/opt/local-path-provisioner#${data_path}#g' \
            -e 's#image: busybox#image: Placeholder_registry/k8s/busybox#g' \
            -e '/provisioner: rancher.io/i \\  annotations:\n\    defaultVolumeType: local' \
            ${download_path}/${localpath_file} >${pkg_path}/yaml/${localpath_file}" \
        "grep -q 'Placeholder_registry/k8s' ${pkg_path}/yaml/${localpath_file} && grep -q '${data_path}' ${pkg_path}/yaml/${localpath_file}"

    make_one_yaml "${metrics_file}" "${download_path}/${metrics_file}" \
        "${metrics_version}" \
        "sed -e 's#image: registry.k8s.io/metrics-server#image: Placeholder_registry/k8s#g' \
            -e '/- --metric-resolution=15s/a\\        - --kubelet-insecure-tls' \
            ${download_path}/${metrics_file} >${pkg_path}/yaml/${metrics_file}" \
        "grep -q 'image: Placeholder_registry/k8s/metrics-server' ${pkg_path}/yaml/${metrics_file} && grep -q -- '--kubelet-insecure-tls' ${pkg_path}/yaml/${metrics_file}"

    make_one_yaml "${calico_file}" "${download_path}/${calico_file}" \
        "${calico_version}|${cluster_cidr}" \
        "sed -e 's#image: quay.io/calico#image: Placeholder_registry/k8s#g' \
            -e 's/# - name: CALICO_IPV4POOL_CIDR/- name: CALICO_IPV4POOL_CIDR/' \
            -e 's@#   value: \"192.168.0.0/16\"@  value: \"${cluster_cidr}\"@' \
            -e '/value: \"autodetect\"/a\\            - name: IP_AUTODETECTION_METHOD\n              value: \"kubernetes-internal-ip\"' \
            ${download_path}/${calico_file} >${pkg_path}/yaml/${calico_file}" \
        "grep -q 'IP_AUTODETECTION_METHOD' ${pkg_path}/yaml/${calico_file} && grep -q 'Placeholder_registry' ${pkg_path}/yaml/${calico_file} && grep -q 'value: \"${cluster_cidr}\"' ${pkg_path}/yaml/${calico_file}"
}

function make_tgz() {
    h2 "make tgz"
    if [ ! -d ${pkg_path}/tgz ]; then mkdir -p ${pkg_path}/tgz; fi

    local target=${pkg_path}/tgz/${nerdctl_file}
    if [ -f "${target}" ] && cache_valid "tgz-nerdctl" "${target}" "${nerdctl_version}" "${arch_name}"; then
        note "pkg ${nerdctl_file} exists"
        return 0
    fi
    if cp ${download_path}/${nerdctl_file} ${target}; then
        cache_commit "tgz-nerdctl" "${nerdctl_version}" "${arch_name}"
        success "make nerdctl containerd"
    else
        error "make ${nerdctl_file} failed"
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
        # .stamps 仅为构建机缓存失效依据, 不进入离线包
        if tar --transform='s,^,k8s-deploy/,' --exclude='pkg/.stamps' -zcf ${target_name} \
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
