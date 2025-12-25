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
    download "${flannel_url}" "${flannel_file}"
    download "${localpath_url}" "${localpath_file}"
    download "${kubernetes_url}" "${kubernetes_file}"
    download "${coredns_url}" "${coredns_file}.base"
    download "${metrics_url}" "${metrics_file}"
    download "${k9s_url}" "${k9s_file}"
    download "${calico_url}" "${calico_file}"
}

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

    if [ ! -f ${pkg_path}/yaml/${flannel_file} ]; then
        sed -e 's#image: ghcr.io/flannel-io#image: Placeholder_registry/k8s#g' \
            ${download_path}/${flannel_file} >${pkg_path}/yaml/${flannel_file} && success "make ${flannel_file}"
    else
        note "yaml ${flannel_file} exists"
    fi

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
            ${download_path}/${calico_file} >${pkg_path}/yaml/${calico_file} && success "make ${calico_file}"
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

function make_registry() {
    h2 "make registry"
    if [ ! -d ${pkg_path}/image ]; then mkdir -p ${pkg_path}/image; fi

    if [ ! -f ${pkg_path}/image/${registry_file} ]; then
        docker pull --platform linux/${arch_name} ${registry_image} && docker save ${registry_image} >${pkg_path}/image/${registry_file}
        success "saved ${registry_image}"
    else
        note "${pkg_path}/image/${registry_file} exists"
    fi
}

function make_haproxy() {
    h2 "make haproxy"
    if [ ! -d ${pkg_path}/image ]; then mkdir -p ${pkg_path}/image; fi

    if [ ! -f ${pkg_path}/image/${haproxy_file} ]; then
        docker pull --platform linux/${arch_name} ${haproxy_image} && docker save ${haproxy_image} >${pkg_path}/image/${haproxy_file}
    else
        note "${pkg_path}/image/${haproxy_file} exists"
    fi
}

function make_image() {
    h2 "make image"
    if [ ! -d ${pkg_path}/image ]; then mkdir -p ${pkg_path}/image; fi

    if [ ! -f ${pkg_path}/image/${image_file} ]; then
        registry_port=5001
        local_reg=127.0.0.1:${registry_port}/k8s
        if docker ps | grep registry | grep 5001; then
            warn "registry already running, remove it"
            docker ps | grep ":${registry_port}" | awk '{print $1}' | xargs docker rm -f
        fi

        if docker run -d -p ${registry_port}:5000 -v ${download_path}/registry:/var/lib/registry ${registry_image}; then
            success "start registry" && sleep 5

            # pause
            sync_image ${pause_image} "${local_reg}/pause:${pause_version}" && success "make image pause:${pause_version}"

            # flannel
            if [ ${cni_plugin} == 'flannel' ]; then
                for i in $(grep image: ${download_path}/${flannel_file} | awk '{print $2}' | sort | uniq); do
                    img=$(echo $i | awk -F / '{print $NF}')
                    sync_image $i ${local_reg}/${img} && success "make image ${local_reg}/${img}"
                done
            fi

            # calico
            if [ ${cni_plugin} == 'calico' ]; then
                for i in $(grep image: ${download_path}/${calico_file} | awk '{print $2}' | sort | uniq); do
                    img=$(echo $i | awk -F / '{print $NF}')
                    sync_image $i ${local_reg}/${img} && success "make image ${local_reg}/${img}"
                done
            fi

            # coredns
            for i in $(grep image: ${download_path}/${coredns_file}.base | awk '{print $2}' | sort | uniq); do
                img=$(echo $i | awk -F / '{print $NF}')
                sync_image $i ${local_reg}/${img} && success "make image ${local_reg}/${img}"
            done

            # metrics-server
            metrics_yml=${download_path}/${metrics_file}
            for i in $(grep image: ${metrics_yml} | awk '{print $2}' | sort | uniq); do
                img=$(echo $i | awk -F / '{print $NF}')
                sync_image $i ${local_reg}/${img} && docker push ${local_reg}/${img} && success "make image ${local_reg}/${img}"
            done

            # local-path
            for i in $(grep image: ${download_path}/${localpath_file} | awk '{print $2}' | sort | uniq); do
                img=$(echo $i | awk -F / '{print $NF}')
                sync_image $i ${local_reg}/${img} && docker push ${local_reg}/${img} && success "make image ${local_reg}/${img}"
            done
        else
            error "start registry failed"
        fi

        # rm registry container
        docker ps | grep ":${registry_port}" | awk '{print $1}' | xargs docker rm -f
        sync

        # image pkg
        cd ${download_path} && tar cf ${image_file} registry && mv ${image_file} ${pkg_path}/image/ && success "make image pkg ${image_file}"
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
        if tar --transform='s,^,k8s-deploy/,' -zcvf ${target_name} deploy.sh config.ini utils.sh uninstall.sh README.md pkg; then
            success "make target"
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
