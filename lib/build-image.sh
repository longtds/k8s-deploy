# shellcheck shell=bash

function make_registry() {
    h2 "make registry"
    if [ ! -d ${pkg_path}/image ]; then mkdir -p ${pkg_path}/image; fi

    local target=${pkg_path}/image/${registry_file}
    if [ -f "${target}" ] && cache_valid "image-registry" "${target}" "${registry_version}" "${arch_name}"; then
        note "${target} exists"
        return 0
    fi
    if image_pull "${registry_image}" "linux/${arch_name}" && image_save "${registry_image}" "${target}"; then
        cache_commit "image-registry" "${registry_version}" "${arch_name}"
        success "saved ${registry_image}"
    else
        rm -f "${target}"
        error "save ${registry_image} failed"
    fi
}

function make_haproxy() {
    h2 "make haproxy"
    if [ ! -d ${pkg_path}/image ]; then mkdir -p ${pkg_path}/image; fi

    local target=${pkg_path}/image/${haproxy_file}
    if [ -f "${target}" ] && cache_valid "image-haproxy" "${target}" "${haproxy_version}" "${arch_name}"; then
        note "${target} exists"
        return 0
    fi
    if image_pull "${haproxy_image}" "linux/${arch_name}" && image_save "${haproxy_image}" "${target}"; then
        cache_commit "image-haproxy" "${haproxy_version}" "${arch_name}"
        success "saved ${haproxy_image}"
    else
        rm -f "${target}"
        error "save ${haproxy_image} failed"
    fi
}

# 从 YAML 文件中提取镜像列表 (过滤注释与空行, 去重)
function extract_images() {
    local yaml_file="$1"
    grep -E '^[[:space:]]*image:' "${yaml_file}" \
        | sed -e 's/^[[:space:]]*image:[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" \
        | sort -u
}

function make_image() {
    h2 "make image"
    if [ ! -d ${pkg_path}/image ]; then mkdir -p ${pkg_path}/image; fi

    # 任一内置组件版本变化都会使离线镜像包缓存失效
    local image_cache_key="${registry_version}|${pause_version}|${calico_version}|${kubernetes_version}|${metrics_version}|${localpath_version}|${arch_name}"
    local image_target=${pkg_path}/image/${image_file}
    if [ -f "${image_target}" ] && cache_valid "image-bundle" "${image_target}" ${image_cache_key}; then
        note "${image_target} exists"
        return 0
    fi

    local registry_port=5001
    local local_reg="127.0.0.1:${registry_port}/k8s"
    local build_reg_image="k8s-deploy-registry:${registry_version}"

    # 清理可能残留的构建用 registry 容器
    if image_ps | grep -q ":${registry_port}"; then
        warn "registry already running, remove it"
        image_ps | grep ":${registry_port}" | awk '{print $1}' | xargs image_rm 2>/dev/null || true
    fi

    # 构建用 registry 容器需运行在构建机架构上, 与目标架构无关
    local build_reg_src=${registry_image}
    if [ -n "${registry_proxy}" ]; then build_reg_src=${registry_proxy}/${registry_image}; fi
    if image_pull "${build_reg_src}" "linux/${host_arch}"; then
        image_tag "${build_reg_src}" "${build_reg_image}"
    else
        error "pull ${build_reg_src} failed"
    fi

    if image_run -d -p "${registry_port}:5000" -v "${registry_path}:/var/lib/registry" "${build_reg_image}"; then
        success "start registry"
        sleep 5

        # pause
        sync_image "${pause_image}" "${local_reg}/pause:${pause_version}" && success "make image pause:${pause_version}"

        # calico
        for i in $(extract_images "${download_path}/${calico_file}"); do
            img=$(echo "$i" | awk -F / '{print $NF}')
            sync_image "$i" "${local_reg}/${img}" && success "make image ${local_reg}/${img}"
        done

        # coredns
        for i in $(extract_images "${download_path}/${coredns_file}.base"); do
            img=$(echo "$i" | awk -F / '{print $NF}')
            sync_image "$i" "${local_reg}/${img}" && success "make image ${local_reg}/${img}"
        done

        # metrics-server
        for i in $(extract_images "${download_path}/${metrics_file}"); do
            img=$(echo "$i" | awk -F / '{print $NF}')
            sync_image "$i" "${local_reg}/${img}" && success "make image ${local_reg}/${img}"
        done

        # local-path
        for i in $(extract_images "${download_path}/${localpath_file}"); do
            img=$(echo "$i" | awk -F / '{print $NF}')
            sync_image "$i" "${local_reg}/${img}" && success "make image ${local_reg}/${img}"
        done
    else
        error "start registry failed"
    fi

    # 停止构建用 registry 容器
    image_ps | grep ":${registry_port}" | awk '{print $1}' | xargs image_rm 2>/dev/null || true
    sync

    # 打包 registry 数据目录为离线镜像包
    if tar -C "${build_path}" -cf "${image_target}" registry; then
        cache_commit "image-bundle" ${image_cache_key}
        success "make image pkg ${image_file}"
    else
        rm -f "${image_target}"
        error "make image pkg ${image_file} failed"
    fi
}
