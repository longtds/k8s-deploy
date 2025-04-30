#!/bin/bash
# shellcheck disable=all

if [ -f utils.sh ]; then
    source utils.sh
else
    echo "file utils.sh not found."
    exit 1
fi

if [ -f config.ini ]; then
    source config.ini
else
    error "file config.ini not found."
fi

download_path=${run_path}/download
target_path=${run_path}/target

function download_file() {
    h2 "download_file"
    if [ ! -d ${download_path} ]; then mkdir ${download_path}; fi

    download "${cfssl_url}" "${cfssl_file}"
    download "${cfssljson_url}" "${cfssljson_file}"
    download "${etcd_url}" "${etcd_file}"
    download "${nerdctl_url}" "${nerdctl_file}"
    download "${containerd_url}" "${containerd_file}"
    download "${flannel_url}" "${flannel_file}"
    download "${localpath_url}" "${localpath_file}"
    download "${kubernetes_url}" "${kubernetes_file}"
    download "${coredns_url}" "${coredns_file}.base"
    download "${metrics_url}" "${metrics_file}"
}

function make_binary() {
    h2 "make binary"
    if [ ! -d ${pkg_bin_path} ]; then mkdir -p ${pkg_bin_path}; fi

    if [ ! -f ${pkg_bin_path}/cfssl ]; then
        cp ${download_path}/${cfssl_file} ${pkg_bin_path}/cfssl && success "make cfssl successfully"
    else
        note "binary cfssl exists"
    fi

    if [ ! -f ${pkg_bin_path}/cfssljson ]; then
        cp ${download_path}/${cfssljson_file} ${pkg_bin_path}/cfssljson && success "make cfssljson successfully"
    else
        note "binary cfssljson exists"
    fi

    if [ ! -f ${pkg_bin_path}/etcd ]; then
        tar xf ${download_path}/${etcd_file} -C ${pkg_bin_path} --strip-components=1 etcd-v${etcd_version}-linux-${arch_name}/etcd && success "make etcd successfully"
    else
        note "binary etcd exists"
    fi

    if [ ! -f ${pkg_bin_path}/etcdctl ]; then
        tar xf ${download_path}/${etcd_file} -C ${pkg_bin_path} --strip-components=1 etcd-v${etcd_version}-linux-${arch_name}/etcdctl && success "make etcdctl successfully"
    else
        note "binary etcdctl exists"
    fi

    if [ ! -f ${pkg_bin_path}/nerdctl ]; then
        tar xf ${download_path}/${nerdctl_file} -C ${pkg_bin_path} && success "make nerdctl successfully"
    else
        note "binary nerdctl exists"
    fi

    if [ ! -f ${pkg_bin_path}/kube-apiserver ]; then
        tar xf ${download_path}/${kubernetes_file} -C ${pkg_bin_path} --strip-components=3 kubernetes/server/bin/kube-apiserver && success "make kube-apiserver successfully"
    else
        note "binary kube-apiserver exists"
    fi

    if [ ! -f ${pkg_bin_path}/kube-controller-manager ]; then
        tar xf ${download_path}/${kubernetes_file} -C ${pkg_bin_path} --strip-components=3 kubernetes/server/bin/kube-controller-manager && success "make kube-controller-manager successfully"
    else
        note "binary kube-controller-manager exists"
    fi

    if [ ! -f ${pkg_bin_path}/kube-scheduler ]; then
        tar xf ${download_path}/${kubernetes_file} -C ${pkg_bin_path} --strip-components=3 kubernetes/server/bin/kube-scheduler && success "make kube-scheduler successfully"
    else
        note "binary kube-scheduler exists"
    fi

    if [ ! -f ${pkg_bin_path}/kubectl ]; then
        tar xf ${download_path}/${kubernetes_file} -C ${pkg_bin_path} --strip-components=3 kubernetes/server/bin/kubectl && success "make kubectl successfully"
    else
        note "binary kubectl exists"
    fi

    if [ ! -f ${pkg_bin_path}/kubelet ]; then
        tar xf ${download_path}/${kubernetes_file} -C ${pkg_bin_path} --strip-components=3 kubernetes/server/bin/kubelet && success "make kubelet successfully"
    else
        note "binary kubelet exists"
    fi

    if [ ! -f ${pkg_bin_path}/kube-proxy ]; then
        tar xf ${download_path}/${kubernetes_file} -C ${pkg_bin_path} --strip-components=3 kubernetes/server/bin/kube-proxy && success "make kube-proxy successfully"
    else
        note "binary kube-proxy exists"
    fi
}

function make_yaml() {
    h2 "make yaml"
    if [ ! -d ${pkg_yaml_path} ]; then mkdir -p ${pkg_yaml_path}; fi

    if [ ! -f ${pkg_yaml_path}/${flannel_file} ]; then
        sed -e 's#vxlan#Placeholder_flannel_backend#g' \
            -e 's#image: ghcr.io/flannel-io#image: Placeholder_registry/k8s#g' \
            ${download_path}/${flannel_file} >${pkg_yaml_path}/${flannel_file} && success "make ${flannel_file} successfully"
    else
        note "yaml ${flannel_file} exists"
    fi

    if [ ! -f ${pkg_yaml_path}/${coredns_file} ]; then
        sed -e 's/__DNS__SERVER__/10.96.0.1/g' \
            -e 's/__DNS__DOMAIN__/cluster.local/g' \
            -e 's/__DNS__MEMORY__LIMIT__/200Mi/g' \
            -e 's#image: registry.k8s.io/coredns#image: Placeholder_registry/k8s#g' \
            ${download_path}/${coredns_file}.base >${pkg_yaml_path}/${coredns_file} && success "make ${coredns_file} successfully"
    else
        note "yaml ${coredns_file} exists"
    fi

    if [ ! -f ${pkg_yaml_path}/${localpath_file} ]; then
        sed -e 's#image: rancher/#image: Placeholder_registry/k8s/#g' \
            -e "s#/opt/local-path-provisioner#Placeholder_local_path#g" \
            -e 's#image: busybox#image: Placeholder_registry/k8s/busybox#g' \
            -e '/provisioner: rancher.io/i \  annotations:\n\    defaultVolumeType: local' \
            ${download_path}/${localpath_file} >${pkg_yaml_path}/${localpath_file} && success "make ${localpath_file} successfully"
    else
        note "yaml ${localpath_file} exists"
    fi

    if [ ! -f ${pkg_yaml_path}/${metrics_file} ]; then
        sed -e 's#image: registry.k8s.io/metrics-server#image: Placeholder_registry/k8s#g' \
            ${download_path}/${metrics_file} >${pkg_yaml_path}/${metrics_file} && success "make ${metrics_file} successfully"
    else
        note "yaml ${metrics_file} exists"
    fi
}

function make_tgz() {
    h2 "make tgz"
    if [ ! -d ${pkg_tgz_path} ]; then mkdir -p ${pkg_tgz_path}; fi

    if [ ! -f ${pkg_tgz_path}/${containerd_file} ]; then
        cp ${download_path}/${containerd_file} ${pkg_tgz_path}/${containerd_file} && success "make containerd successfully"
    else
        note "pkg ${containerd_file} exists"
    fi
}

function make_registry() {
    h2 "make registry"
    if [ ! -d ${pkg_image_path} ]; then mkdir -p ${pkg_image_path}; fi

    if [ ! -f ${pkg_image_path}/${registry_file} ]; then
        registry_image=registry:${registry_version}
        docker pull --platform linux/${arch_name} ${registry_image} && docker save ${registry_image} >${pkg_image_path}/${registry_file}
    else
        note "${pkg_image_path}/${registry_file} exists"
    fi
}

function make_haproxy() {
    h2 "make haproxy"
    if [ ! -d ${pkg_image_path} ]; then mkdir -p ${pkg_image_path}; fi

    if [ ! -f ${pkg_image_path}/${haproxy_file} ]; then
        haproxy_image=haproxy:${haproxy_version}
        docker pull --platform linux/${arch_name} ${haproxy_image} && docker save ${haproxy_image} >${pkg_image_path}/${haproxy_file}
    else
        note "${pkg_image_path}/${haproxy_file} exists"
    fi
}

function make_image() {
    h2 "make image"
    if [ ! -d ${pkg_image_path} ]; then mkdir -p ${pkg_image_path}; fi

    if [ ! -f ${pkg_image_path}/${image_file} ]; then
        registry_port=5001
        local_reg=127.0.0.1:${registry_port}/k8s
        if docker ps | grep registry | grep 5001; then
            warn "registry already running, remove it"
            docker ps | grep ":${registry_port}" | awk '{print $1}' | xargs docker rm -f
        fi

        if docker run -d -p ${registry_port}:5000 -v ${download_path}/registry:/var/lib/registry registry:${registry_version}; then
            success "start registry successfully" && sleep 5

            # pause
            pause_image="registry.k8s.io/pause:${pause_version}"
            sync_image ${pause_image} "${local_reg}/pause:${pause_version}" && success "make image pause:${pause_version} successfully"

            # flannel
            for i in $(grep image: ${download_path}/${flannel_file} | awk '{print $2}' | sort | uniq); do
                img=$(echo $i | awk -F / '{print $NF}')
                sync_image $i ${local_reg}/${img} && success "make image ${local_reg}/${img} successfully"
            done

            # coredns
            for i in $(grep image: ${download_path}/${coredns_file}.base | awk '{print $2}' | sort | uniq); do
                img=$(echo $i | awk -F / '{print $NF}')
                sync_image $i ${local_reg}/${img} && success "make image ${local_reg}/${img} successfully"
            done

            # metrics-server
            metrics_yml=${download_path}/${metrics_file}
            for i in $(grep image: ${metrics_yml} | awk '{print $2}' | sort | uniq); do
                img=$(echo $i | awk -F / '{print $NF}')
                sync_image $i ${local_reg}/${img} && docker push ${local_reg}/${img} && success "make image ${local_reg}/${img} successfully"
            done

            # local-path
            for i in $(grep image: ${download_path}/${localpath_file} | awk '{print $2}' | sort | uniq); do
                img=$(echo $i | awk -F / '{print $NF}')
                sync_image $i ${local_reg}/${img} && docker push ${local_reg}/${img} && success "make image ${local_reg}/${img} successfully"
            done
        else
            error "start registry failed"
        fi

        # rm registry container
        docker ps | grep ":${registry_port}" | awk '{print $1}' | xargs docker rm -f
        sync

        # image pkg
        cd ${download_path} && tar cf ${image_file} registry && mv ${image_file} ${pkg_image_path}/ && success "make image pkg ${image_file} successfully"
    else
        note "image ${image_file} exists"
    fi
}

function make_target() {
    note "make target"
    if [ ! -d ${target_path} ]; then mkdir -p ${target_path}; fi

    target_name=${target_path}/kubernetes-v${kubernetes_version}-$(date +%Y%m%d)-${arch_name}.tgz

    if [ -d ${pkg_path} ]; then
        cd ${run_path}
        if tar zcvf ${target_name} deploy.sh config.ini utils.sh uninstall.sh Vagrantfile README LICENSE build.sh pkg; then
            success "make target successfully"
        else
            error "make target failed"
        fi
    else
        error "${pkg_path} not found!"
    fi
}

download_file
make_binary
make_yaml
make_tgz
make_registry
make_haproxy
make_image
make_target
