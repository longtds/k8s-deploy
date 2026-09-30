# shellcheck shell=bash

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
        build_reg_image=k8s-deploy-registry:${registry_version}
        if docker ps | grep registry | grep 5001; then
            warn "registry already running, remove it"
            docker ps | grep ":${registry_port}" | awk '{print $1}' | xargs docker rm -f
        fi

        # 构建用registry容器需运行在构建机架构上，与目标架构无关
        build_reg_src=${registry_image}
        if [ -n "${registry_proxy}" ]; then build_reg_src=${registry_proxy}/${registry_image}; fi
        if docker pull --platform linux/${host_arch} ${build_reg_src}; then
            docker tag ${build_reg_src} ${build_reg_image}
        else
            error "pull ${build_reg_src} failed"
        fi

        if docker run -d -p ${registry_port}:5000 -v ${registry_path}:/var/lib/registry ${build_reg_image}; then
            success "start registry" && sleep 5

            # pause
            sync_image ${pause_image} "${local_reg}/pause:${pause_version}" && success "make image pause:${pause_version}"

            # calico
            for i in $(grep image: ${download_path}/${calico_file} | awk '{print $2}' | sort | uniq); do
                img=$(echo $i | awk -F / '{print $NF}')
                sync_image $i ${local_reg}/${img} && success "make image ${local_reg}/${img}"
            done

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
        if tar -C ${build_path} -cf ${pkg_path}/image/${image_file} registry; then
            success "make image pkg ${image_file}"
        else
            error "make image pkg ${image_file} failed"
        fi
    else
        note "image ${image_file} exists"
    fi
}

