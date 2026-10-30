# shellcheck shell=bash
# shellcheck disable=SC2068

# 部署前配置校验: IP/主机名配对、网络配置完整性, 避免错误配置在流程中段才暴露
function validate_config() {
    [ ${#node_ip[@]} -gt 0 ] || error "node_ip is empty"
    [ ${#node_ip[@]} -eq ${#node_hostname[@]} ] || error "node_ip and node_hostname count mismatch"
    [ ${#addnode_ip[@]} -eq ${#addnode_hostname[@]} ] || error "addnode_ip and addnode_hostname count mismatch"

    case "${kubeproxy_mode}" in
    iptables | nftables | ipvs) ;;
    *) error "invalid kubeproxy_mode: '${kubeproxy_mode}', expect iptables, nftables or ipvs" ;;
    esac

    local v
    for v in service_cidr cluster_cidr cluster_dns cluster_domain; do
        [ -n "${!v}" ] || error "config ${v} is empty (see config.ini)"
    done

    [ "${service_cidr}" != "${cluster_cidr}" ] || error "service_cidr and cluster_cidr must not be the same"
    [[ "${cluster_dns}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || error "cluster_dns must be a valid IPv4 address"
}

function check_pkg() {
    pkg_bin_list=(cfssl cfssljson etcd etcdctl kube-apiserver kube-controller-manager kube-scheduler kubelet kube-proxy kubectl)
    pkg_yaml_list=(${coredns_file} ${localpath_file} ${metrics_file})
    pkg_image_list=(${registry_file} ${haproxy_file} ${image_file})
    pkg_tgz_list=(${nerdctl_file})

    for i in ${pkg_bin_list[@]}; do
        if [ ! -f ${pkg_path}/bin/${i} ]; then
            error "${pkg_path}/bin/${i} not found"
        fi
    done

    for i in ${pkg_yaml_list[@]}; do
        if [ ! -f ${pkg_path}/yaml/${i} ]; then
            error "${pkg_path}/yaml/${i} not found"
        fi
    done

    for i in ${pkg_image_list[@]}; do
        if [ ! -f ${pkg_path}/image/${i} ]; then
            error "${pkg_path}/image/${i} not found"
        fi
    done

    for i in ${pkg_tgz_list[@]}; do
        if [ ! -f ${pkg_path}/tgz/${i} ]; then
            error "${pkg_path}/tgz/${i} not found"
        fi
    done
}

function check_node_pkg() {
    h2 "check node dependency"

    local node_bin_list pkg_failed check_failed host host_failed command check_out ssh_err missing missing_warn kver
    local miss_prefix="MISS_$$" warn_prefix="WARN_$$" kver_prefix="KVER_$$"

    # kubeproxy_mode 取值校验已在 validate_config 中提前完成

    # kube-proxy/CNI 运行期强依赖的系统命令，缺失会导致安装"成功"但集群不可用
    # ipvs 模式同样依赖 ipset(kube-proxy 用其维护 ipvs 后端列表), 已在下方列表中
    node_bin_list=(iptables socat ipset conntrack ip)
    if [ "${kubeproxy_mode}" == "nftables" ]; then
        node_bin_list+=(nft)
    fi

    # 输出带唯一前缀，避免 MOTD/banner 等无关 stdout 被误判为缺失依赖
    command="for b in ${node_bin_list[*]}; do command -v \${b} >/dev/null 2>&1 || echo ${miss_prefix}:\${b}; done
command -v chronyc >/dev/null 2>&1 || echo ${warn_prefix}:chronyc
echo ${kver_prefix}:\$(uname -r)"

    pkg_failed=0
    check_failed=0
    for host in "$@"; do
        host_failed=0
        ssh_err=""
        if ! check_out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -i ${ssh_key} -p ${ssh_port} \
            ${ssh_user}@${host} "${command}" 2>&1); then
            ssh_err=$(echo "${check_out}" | tail -n 1)
            warn "${host} unreachable: ${ssh_err}"
            check_failed=1
            continue
        fi

        missing=$(echo "${check_out}" | sed -n "s/^${miss_prefix}://p" | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')
        missing_warn=$(echo "${check_out}" | sed -n "s/^${warn_prefix}://p" | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')

        # nftables 模式要求内核 >= 5.13，否则 kube-proxy 无法启动
        if [ "${kubeproxy_mode}" == "nftables" ]; then
            kver=$(echo "${check_out}" | sed -n "s/^${kver_prefix}://p" | head -n 1 | cut -d. -f1,2)
            if [ -n "${kver}" ] && [ "$(printf '%s\n' "5.13" "${kver}" | sort -V | head -n 1)" != "5.13" ]; then
                warn "${host} kernel ${kver} < 5.13, nftables mode requires kernel >= 5.13"
                host_failed=1
            fi
        fi

        if [ -n "${missing_warn}" ]; then
            warn "${host} missing optional: ${missing_warn} (time sync will be skipped)"
        fi

        if [ -n "${missing}" ]; then
            warn "${host} missing required: ${missing}"
            pkg_failed=1
            host_failed=1
        fi

        if [ ${host_failed} -ne 0 ]; then
            check_failed=1
        else
            success "${host} dependency ok"
        fi
    done

    if [ ${pkg_failed} -ne 0 ]; then
        note "install them first, e.g.
  rhel/anolis/kylin/openeuler:  dnf install -y nftables iptables-nft socat ipset conntrack-tools chrony
  debian/ubuntu:                apt install -y nftables iptables socat ipset conntrack chrony"
    fi

    if [ ${check_failed} -ne 0 ]; then
        error "node dependency check failed"
    fi
}

# 检测节点是否已有 Docker/containerd 在运行, 提示共存注意事项
# 当前部署使用独立 containerd root/state/service 与已有 Docker 隔离, 但:
#   - /etc/containerd/config.toml 会被覆盖为 k8s containerd 配置
#   - 卸载后 Docker 自带的 containerd 可能需要重新拉起 (被同名 service 抢占)
function check_existing_docker() {
    h2 "check existing docker/containerd"

    local command docker_found host any_found=0

    # 检测项: docker 二进制存在 / systemd containerd.service 活跃 / systemd docker.service 活跃
    command="if command -v docker >/dev/null 2>&1; then echo DOCKER_BIN; fi
if systemctl is-active --quiet containerd.service 2>/dev/null; then echo CONTAINERD_ACTIVE; fi
if systemctl is-active --quiet docker.service 2>/dev/null; then echo DOCKER_ACTIVE; fi"

    for host in "$@"; do
        docker_found=""
        if docker_found=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -i ${ssh_key} -p ${ssh_port} \
            ${ssh_user}@${host} "${command}" 2>/dev/null); then
            if [ -n "${docker_found}" ]; then
                any_found=1
                warn "${host}: detected pre-existing container runtime (${docker_found//$'\n'/,})"
            fi
        fi
    done

    if [ ${any_found} -ne 0 ]; then
        note "k8s containerd uses isolated paths (${containerd_root}, ${containerd_state})"
        note "to coexist with Docker, but please be aware:"
        note "  1. /etc/containerd/config.toml will be overwritten with k8s settings"
        note "  2. Docker's containerd.service may be masked — after uninstall, run:"
        note "     systemctl start containerd.service docker.service"
        note "  3. Docker's container/ images/ volumes are NOT affected by k8s uninstall"
    else
        success "no existing docker/containerd detected"
    fi
}
