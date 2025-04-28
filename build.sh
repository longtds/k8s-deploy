#!/bin/bash
# shellcheck disable=all

set +e
set -o noglob

bold=$(tput bold)
underline=$(tput sgr 0 1)
reset=$(tput sgr0)
red=$(tput setaf 1)
green=$(tput setaf 76)
blue=$(tput setaf 25)

success() {
    printf "$(TZ=UTC-8 date +%Y-%m-%d" "%H:%M:%S) ${green}✔ %s${reset}\n" "$@"
}
error() {
    printf "${red}✖ %s${reset}\n" "$@"
    exit 2
}
note() {
    printf "\n${underline}${bold}${blue}Note:${reset} ${blue}%s${reset}\n" "$@"
}

set -e

if [ -f config.ini ]; then
    source config.ini
else
    error "Configuration file config.ini not found."
fi

if [ ${arch} == "x86_64" ]; then
    note "x86_64"
    arch_name=amd64
elif [ ${arch} == "aarch64" ]; then
    note "aarch64"
    arch_name=arm64
else
    error "arch error, only support x86_64 and aarch64"
fi

download_path=${run_path}/download
target_path=${run_path}/target

if [ ! -d ${target_path} ]; then mkdir ${target_path}; fi
if [ ! -d ${pkg_path} ]; then mkdir ${pkg_path}; fi
if [ ! -d ${download_path} ]; then mkdir ${download_path}; fi

cfssl_file=cfssl_${cfssl_version}_linux_${arch_name}
cfssl_url=https://github.com/cloudflare/cfssl/releases/download/v${cfssl_version}/${cfssl_file}
cfssljson_file=cfssljson_${cfssl_version}_linux_${arch_name}
cfssljson_url=https://github.com/cloudflare/cfssl/releases/download/v${cfssl_version}/${cfssljson_file}
etcd_file=etcd-v${etcd_version}-linux-${arch_name}.tar.gz
etcd_url=https://github.com/etcd-io/etcd/releases/download/v${etcd_version}/${etcd_file}
nerdctl_file=nerdctl-${nerdctl_version}-linux-${arch_name}.tar.gz
nerdctl_url=https://github.com/containerd/nerdctl/releases/download/v${nerdctl_version}/${nerdctl_file}
containerd_file=cri-containerd-cni-${containerd_version}-linux-${arch_name}.tar.gz
containerd_url=https://github.com/containerd/containerd/releases/download/v${containerd_version}/${containerd_file}
kubernetes_file=kubernetes-server-linux-${arch_name}.tar.gz
kubernetes_url=https://dl.k8s.io/v${kubernetes_version}/${kubernetes_file}
flannel_file=kube-flannel.yml
flannel_url=https://github.com/flannel-io/flannel/releases/download/v${flannel_version}/${flannel_file}
localpath_file=local-path-storage.yaml
localpath_url=https://raw.githubusercontent.com/rancher/local-path-provisioner/v${localpath_version}/deploy/${localpath_file}
longhorn_file=longhorn.yaml
longhorn_url=https://raw.githubusercontent.com/longhorn/longhorn/v${longhorn_version}/deploy/longhorn.yaml
cilium_cli_file=cilium-cli-${cilium_cli_version}-${arch_name}.tar.gz
cilium_cli_url=https://github.com/cilium/cilium-cli/releases/download/v${cilium_cli_version}/cilium-linux-${arch_name}.tar.gz
cilium_file=cilium-${cilium_version}.tar.gz
cilium_url=https://github.com/cilium/cilium/archive/refs/tags/v${cilium_version}.tar.gz
helm_url=https://get.helm.sh/helm-v${helm_version}-linux-${arch_name}.tar.gz
helm_file=helm-${helm_version}-${arch_name}.tar.gz
coredns_file=coredns-${coredns_version}.tgz
coredns_url=https://github.com/coredns/deployment/releases/download/coredns-${coredns_version}/coredns-${coredns_version}.tgz
metrics_file=metrics-server-${metrics_version}.yaml
metrics_file=https://github.com/kubernetes-sigs/metrics-server/releases/download/v${metrics_version}/components.yaml

function download {
    file_url="$1"
    file_name="$2"

    if [ -f "${download_path}/${file_name}" ]; then
        note "${download_path}/${file_name} exists"
        return 0
    fi

    note "download ${file_url}"
    curl -L --progress-bar "${file_url}" -o "${download_path}/${file_name}"
    return $?
}

function download_file {
    note "download_file"
    if download "${cfssl_url}" "${cfssl_file}"; then success "download cfssl successfully"; fi
    if download "${cfssljson_url}" "${cfssljson_file}"; then success "download cfssljson successfully"; fi
    if download "${etcd_url}" "${etcd_file}"; then success "download etcd successfully"; fi
    if download "${nerdctl_url}" "${nerdctl_file}"; then success "download nerdctl successfully"; fi
    if download "${containerd_url}" "${containerd_file}"; then success "download containerd successfully"; fi
    if download "${flannel_url}" "${flannel_file}"; then success "download flannel successfully"; fi
    if download "${localpath_url}" "${localpath_file}"; then success "download localpath successfully"; fi
    if download "${kubernetes_url}" "${kubernetes_file}"; then success "download kubernetes successfully"; fi
    if download "${longhorn_url}" "${longhorn_file}"; then success "download longhorn successfully"; fi
    if download "${cilium_cli_url}" "${cilium_cli_file}"; then success "download cilium-cli successfully"; fi
    if download "${cilium_url}" "${cilium_file}"; then success "download cilium successfully"; fi
    if download "${helm_url}" "${helm_file}"; then success "download cilium successfully"; fi
    if download "${coredns_url}" "${coredns_file}"; then success "download cilium successfully"; fi
    if download "${metrics_url}" "${metrics_file}"; then success "download cilium successfully"; fi
}

function make_cfssl {
    if [ -f "${pkg_path}/${cfssl_pkg}" ]; then
        note "${pkg_path}/${cfssl_pkg} exists"
        return 0
    else
        note "make cfssl"
        cd ${download_path} && cp ${cfssl_file} cfssl && cp ${cfssljson_file} cfssljson && chmod +x cfssl cfssljson
        tar zcf ${cfssl_pkg} cfssl cfssljson && mv ${cfssl_pkg} ${pkg_path}/ && cd ${run_path}
    fi
}

function make_etcd {
    if [ -f "${pkg_path}/${etcd_pkg}" ]; then
        note "${pkg_path}/${etcd_pkg} exists"
        return 0
    else
        note "make etcd"
        cd ${download_path} && tar zxf ${etcd_file} && mv etcd-v${etcd_version}-linux-${arch_name}/{etcdctl,etcd,etcdutl} .
        tar zcf ${etcd_pkg} etcd etcdctl etcdutl && mv ${etcd_pkg} ${pkg_path}/ && cd ${run_path}
    fi
}

function make_containerd {
    if [ -f "${pkg_path}/${containerd_pkg}" ]; then
        note "${pkg_path}/${containerd_pkg} exists"
        return 0
    else
        note "make containerd"
        cp ${download_path}/${containerd_file} ${pkg_path}/${containerd_pkg}
    fi
}

function make_nerdctl {
    if [ -f "${pkg_path}/${nerdctl_pkg}" ]; then
        note "${pkg_path}/${nerdctl_pkg} exists"
        return 0
    else
        note "make nerdctl"
        cp ${download_path}/${nerdctl_file} ${pkg_path}/${nerdctl_pkg}
    fi
}

function make_kubernetes {
    if [ -f "${pkg_path}/${kubernetes_pkg}" ]; then
        note "${pkg_path}/${kubernetes_pkg} exists"
        return 0
    else
        note "make kubernetes"
        cd ${download_path} && tar zxf ${kubernetes_file} && mv kubernetes/server/bin/{kube-apiserver,kube-controller-manager,kube-scheduler,kubectl,kubelet,kube-proxy} .
        tar zcf ${kubernetes_pkg} kube-apiserver kube-controller-manager kube-scheduler kubectl kubelet kube-proxy && mv ${kubernetes_pkg} ${pkg_path}/ && cd ${run_path}
    fi
}

function make_flannel {
    if [ -f "${pkg_path}/${flannel_pkg}" ]; then
        note "${pkg_path}/${flannel_pkg} exists"
        return 0
    else
        note "make flannel"
        sed -e 's#vxlan#Placeholder_flannel_backend#g' \
            -e 's#docker.io/flannel#Placeholder_registry/k8s#g' \
            ${download_path}/${flannel_file} > ${pkg_path}/${flannel_pkg}
    fi
}

function make_coredns {
    if [ -f ${pkg_path}/${coredns_pkg} ]; then
        note "${pkg_path}/${coredns_pkg} exists"
        return 0
    else
        note "make coredns"
        cp ${download_path}/${coredns_file} ${pkg_path}/${coredns_pkg}
    fi
}

function make_helm {
    if [ -f ${pkg_path}/${helm_pkg} ]; then
        note "${pkg_path}/${helm_pkg} exists"
        return 0
    else
        note "make helm"
        cd ${download_path}
        tar xf ${helm_file} &&
        cp ${helm_file} ${pkg_path}/${helm_pkg}
        cd ${run_path}
    fi
}

function make_metrics {
    if [ -f ${pkg_path}/${metrics_pkg} ]; then
        note "${pkg_path}/${metrics_pkg} exists"
        return 0
    else
        note "make metrics"
        sed -e 's#registry.k8s.io/metrics-server#Placeholder_registry/k8s#g' \
            ${download_path}/${metrics_file} > ${pkg_path}/${metrics_pkg}
    fi
}

function make_localpath {
    if [ -f ${pkg_path}/${localpath_pkg} ]; then
        note "${pkg_path}/${localpath_pkg} exists"
        return 0
    else
        note "make localpath"
        sed -e 's#rancher/#Placeholder_registry/k8s/#g' \
            -e "s#/opt/local-path-provisioner#Placeholder_pvc_path#g" \
            -e 's#busybox#Placeholder_registry/k8s/busybox#g' \
            -e '/provisioner: rancher.io/i \  annotations:\n\    defaultVolumeType: local' \
            ${download_path}/${localpath_file} >${pkg_path}/${localpath_pkg}
    fi
}

function make_longhorn {
    if [ -f ${pkg_path}/${longhorn_pkg} ]; then
        note "${pkg_path}/${longhorn_pkg} exists"
        return 0
    else
        note "make longhorn"
        sed -e 's#longhornio/#Placeholder_registry/k8s/#g' \
            -e "s#numberOfReplicas: \"3\"#numberOfReplicas: \"2\"#g" \
            ${download_path}/${longhorn_file} >${pkg_path}/${longhorn_pkg}
    fi
}

function make_cilium {
    if [ -f ${pkg_path}/${cilium_cli_pkg} ]; then
        note "${pkg_path}/${cilium_cli_pkg} exists"
        return 0
    else
        note "make cilium cli"
        cp ${download_path}/${cilium_cli_file} ${pkg_path}/${cilium_cli_pkg}
    fi

    if [ -f ${pkg_path}/${cilium_pkg} ]; then
        note "${pkg_path}/${cilium_pkg} exists"
        return 0
    else
        note "make cilium"
        cd ${download_path} && tar zxf ${cilium_file} && mv cilium-${cilium_version}/install/kubernetes/cilium ./ &&
            tar zcf ${cilium_pkg} cilium && mv ${cilium_pkg} ${pkg_path}/ && cd ${run_path}
    fi

}

function make_registry {
    if [ -f ${pkg_path}/${registry_pkg} ]; then
        note "${pkg_path}/${registry_pkg} exists"
        return 0
    else
        registry_image=registry:${registry_version}
        docker pull ${registry_image}
        docker tag ${registry_image} registry && docker save registry >${pkg_path}/${registry_pkg}
    fi
}

function make_haproxy {
    if [ -f ${pkg_path}/${haproxy_pkg} ]; then
        note "${pkg_path}/${haproxy_pkg} exists"
        return 0
    else
        haproxy_image=haproxy:${haproxy_version}
        docker pull ${haproxy_image}
        docker tag ${haproxy_image} haproxy && docker save haproxy >${pkg_path}/${haproxy_pkg}
    fi
}

function make_image {
    if [ -f ${pkg_path}/${image_pkg} ]; then
        note "${pkg_path}/${image_pkg} exists"
        return 0
    else
        local_reg=127.0.0.1:5000/k8s
        if docker ps -a | grep registry; then
            docker stop registry && docker rm registry
        fi

        if docker run --name registry -d -p 5000:5000 -v ${download_path}/registry:/var/lib/registry ${registry_image}; then
            success "start registry successfully" && sleep 5

            # pause
            pause_image=registry.k8s.io/pause:3.8
            docker pull ${pause_image} &&
                docker tag ${pause_image} ${local_reg}/pause:3.8 &&
                docker push ${local_reg}/pause:3.8 && success "make ${local_reg}/pause:3.8 successfully"

            # flannel
            for i in $(grep image: ${download_path}/${flannel_file} | awk '{print $2}' | sort | uniq); do
                img=$(echo $i | awk -F / '{print $NF}')
                docker pull $i && docker tag $i ${local_reg}/${img} && docker push ${local_reg}/${img} && success "make ${local_reg}/${img} successfully"
            done

            # coredns
            coredns_yml=${download_path}/kubernetes/cluster/addons/dns/coredns/coredns.yaml.base
            for i in $(grep image: ${coredns_yml} | awk '{print $2}' | sort | uniq); do
                img=$(echo $i | awk -F / '{print $NF}')
                docker pull $i && docker tag $i ${local_reg}/${img} && docker push ${local_reg}/${img} && success "make ${local_reg}/${img} successfully"
            done

            # metrics-server
            metrics_yml=${download_path}/kubernetes/cluster/addons/metrics-server/metrics-server-deployment.yaml
            for i in $(grep image: ${metrics_yml} | awk '{print $2}' | sort | uniq); do
                img=$(echo $i | awk -F / '{print $NF}')
                docker pull $i && docker tag $i ${local_reg}/${img} && docker push ${local_reg}/${img} && success "make ${local_reg}/${img} successfully"
            done

            # local-path
            for i in $(grep image: ${download_path}/${localpath_file} | awk '{print $2}' | sort | uniq); do
                img=$(echo $i | awk -F / '{print $NF}')
                docker pull $i && docker tag $i ${local_reg}/${img} && docker push ${local_reg}/${img} && success "make ${local_reg}/${img} successfully"
            done

            # longhorn
            for i in $(grep longhornio ${download_path}/${longhorn_file} | awk '{print $2}' | sed 's/\"//g' | sort | uniq); do
                img=$(echo $i | awk -F / '{print $NF}')
                docker pull $i && docker tag $i ${local_reg}/${img} && docker push ${local_reg}/${img} && success "make ${local_reg}/${img} successfully"
            done

            # cilium
            cilium_images=(cilium:v${cilium_version} operator-generic:v${cilium_version}
                cilium-envoy:v1.30.9-1737073743-40a016d11c0d863b772961ed0168eea6fe6b10a5
                hubble-relay:v${cilium_version} hubble-ui-backend:v0.13.1 hubble-ui:v0.13.1)
            for i in ${cilium_images[@]}; do
                docker pull quay.io/cilium/$i && docker tag quay.io/cilium/$i ${local_reg}/$i && docker push ${local_reg}/$i && success "make ${local_reg}/$i successfully"
            done

            # image pkg
            cd ${download_path} && tar zcf ${image_pkg} registry && mv ${image_pkg} ${pkg_path}/ && success "make ${image_pkg} successfully"
            docker stop registry && docker rm registry && success "stop and remove registry"
        fi
    fi
}

function make_pkg {
    note "make pkg"
    if make_cfssl; then success "make cfssl successfully"; fi
    if make_etcd; then success "make etcd successfully"; fi
    if make_containerd; then success "make containerd successfully"; fi
    if make_nerdctl; then success "make nerdctl successfully"; fi
    if make_kubernetes; then success "make kubernetes successfully"; fi
    if make_coredns; then success "make coredns successfully"; fi
    if make_metrics; then success "make metrics successfully"; fi
    if make_flannel; then success "make flannel successfully"; fi
    if make_localpath; then success "make localpath successfully"; fi
    if make_longhorn; then success "make longhorn successfully"; fi
    if make_cilium; then success "make cilium successfully"; fi
    if make_helm; then success "make helm successfully"; fi
    if make_registry; then success "make registry successfully"; fi
    if make_haproxy; then success "make haproxy successfully"; fi
    if make_image; then success "make image successfully"; fi
}

function make_target {
    note "make target"
    target_name=${target_path}/kubernetes-v${kubernetes_version}-$(date +%Y%m%d)-${arch_name}.tgz
    if [ -d ${pkg_path} ]; then
        cd ${run_path}
        if tar zcvf ${target_name} deploy.sh config.ini uninstall.sh pkg; then
            success "make target successfully"
        else
            error "make target failed"
        fi
    else
        error "${pkg_path} not found!"
    fi
}

download_file
make_pkg
make_target
