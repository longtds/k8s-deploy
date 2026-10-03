# shellcheck shell=bash
# shellcheck disable=SC2068

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

    # kube-proxy 配置模式取值校验：拼写错误会生成非法 kube-proxy 配置
    case "${kubeproxy_mode}" in
    iptables | nftables | ipvs) ;;
    *) error "invalid kubeproxy_mode: '${kubeproxy_mode}', expect iptables, nftables or ipvs (see config.ini)" ;;
    esac

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
