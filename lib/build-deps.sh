# shellcheck shell=bash

# ---------------------------------------------------------------------------
# 系统依赖离线包下载
#
# 依赖命令清单与 preflight.sh check_node_pkg() 保持一致：
#   rhel: nftables iptables-nft socat ipset conntrack-tools iproute chrony kernel-modules-extra
#   deb:  nftables iptables socat ipset conntrack iproute2 chrony
#
# 通过容器内包管理器下载所有 .rpm/.deb 及其依赖，分别保存到 pkg/deps/{rhel,deb}
# ---------------------------------------------------------------------------

function _deps_container_cleanup() {
    image_ps | grep -q "k8s-deploy-deps-download" && \
        image_ps | grep "k8s-deploy-deps-download" | awk '{print $1}' | xargs image_rm 2>/dev/null || true
}

# 为容器注入宿主机代理环境变量，避免容器内无法访问外网
# 若代理指向 127.0.0.1/localhost，自动切换为 host 网络模式
function _deps_proxy_args() {
    local args=""
    local proxy_host=""

    if [ -n "${http_proxy:-}" ]; then
        proxy_host=$(echo "${http_proxy}" | sed -n 's|http://\([^:]*\):.*|\1|p')
        if [ "${proxy_host}" == "127.0.0.1" ] || [ "${proxy_host}" == "localhost" ]; then
            args="${args} --network host"
        fi
        args="${args} -e http_proxy=${http_proxy}"
    fi
    [ -n "${https_proxy:-}" ] && args="${args} -e https_proxy=${https_proxy}"
    [ -n "${no_proxy:-}" ] && args="${args} -e no_proxy=${no_proxy}"
    echo "${args}"
}

function _make_deps_rhel() {
    local out_dir="${pkg_path}/deps/rhel"
    local deps_image="${deps_rhel_image}"
    local deps_pkgs="nftables iptables-nft socat ipset conntrack-tools iproute chrony kernel-modules-extra"

    if [ -n "${registry_proxy}" ]; then deps_image="${registry_proxy}/${deps_image}"; fi

    if [ -d "${out_dir}" ] && [ -n "$(ls -A "${out_dir}" 2>/dev/null)" ]; then
        note "deps rhel exists"
        return 0
    fi

    note "download rhel deps via ${deps_image}"
    mkdir -p "${out_dir}"

    if ! image_pull "${deps_image}" "linux/${arch_name}"; then
        error "pull ${deps_image} failed"
    fi

    # 容器内使用 dnf download 下载包及其全部依赖到 /output
    # 注意: rockylinux 官方镜像使用默认 yum repo, 无需额外配置
    if ! image_run --rm --name "k8s-deploy-deps-download-rhel" \
        $(_deps_proxy_args) \
        -v "${out_dir}:/output" \
        "${deps_image}" \
        /bin/bash -c "
            dnf install -y 'dnf-command(download)' &&
            dnf download -y --resolve --destdir=/output ${deps_pkgs}
        "; then
        error "dnf download rhel deps failed"
    fi

    success "make deps rhel ($(ls "${out_dir}" | wc -l) pkgs)"
}

function _make_deps_deb() {
    local out_dir="${pkg_path}/deps/deb"
    local deps_image="${deps_deb_image}"
    local deps_pkgs="nftables iptables socat ipset conntrack iproute2 chrony"

    if [ -n "${registry_proxy}" ]; then deps_image="${registry_proxy}/${deps_image}"; fi

    if [ -d "${out_dir}" ] && [ -n "$(ls -A "${out_dir}" 2>/dev/null)" ]; then
        note "deps deb exists"
        return 0
    fi

    note "download deb deps via ${deps_image}"
    mkdir -p "${out_dir}"

    if ! image_pull "${deps_image}" "linux/${arch_name}"; then
        error "pull ${deps_image} failed"
    fi

    # 容器内使用 apt-get download 下载包及其全部依赖到 /output
    if ! image_run --rm --name "k8s-deploy-deps-download-deb" \
        $(_deps_proxy_args) \
        -v "${out_dir}:/output" \
        "${deps_image}" \
        /bin/bash -c "
            apt-get update -o Acquire::Languages=none &&
            apt-get install -y --download-only --reinstall ${deps_pkgs} &&
            cp -v /var/cache/apt/archives/*.deb /output/
        "; then
        error "apt download deb deps failed"
    fi

    success "make deps deb ($(ls "${out_dir}" | wc -l) pkgs)"
}

function make_deps() {
    h2 "make deps"

    if [ ! -d "${pkg_path}/deps" ]; then
        mkdir -p "${pkg_path}/deps"
    fi

    _deps_container_cleanup
    _make_deps_rhel
    _make_deps_deb
    _deps_container_cleanup
}
