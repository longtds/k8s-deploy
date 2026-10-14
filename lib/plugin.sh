# shellcheck shell=bash
# ---------------------------------------------------------------------------
# 可选插件运行时引擎(随主离线包分发)
#
# 插件目录约定(插件 tgz 解压到部署目录后的布局):
#   plugins/<name>/plugin.conf         元数据(bash 变量):
#                                      plugin_name/plugin_version/
#                                      plugin_description/plugin_namespace/
#                                      plugin_manifests=(...)
#   plugins/<name>/hooks.sh           可选钩子: plugin_pre_install(失败的组合
#                                      可在此拒绝安装) / plugin_ready /
#                                      plugin_post_install / plugin_pre_remove
#   plugins/<name>/manifests/*.yaml   构建期渲染好的静态清单(镜像占位符
#                                      Placeholder_registry, 与核心组件一致)
#   plugins/<name>/images/registry.tar  该插件镜像的 registry 存储数据子集
#
# 新增插件无需修改本文件: 构建期产出符合上述约定的目录并打成独立 tgz 即可。
# ---------------------------------------------------------------------------

plugin_stamp_dir=${run_path}/.plugin-stamps

function plugin_kubectl() {
    "${pkg_path}/bin/kubectl" --kubeconfig "${run_path}/admin.kubeconfig" "$@"
}

function plugin_usage() {
    echo "Usage: ./deploy.sh plugin <command> [name]
  Commands:
    list              列出已解压插件及安装状态
    install <name>    安装插件
    remove <name>     卸载插件
    status [name]     查看插件运行状态(省略 name 等同 list)"
}

# 枚举 plugins/ 下含 plugin.conf 的插件名(全局 noglob 下用 find)
function _plugin_list_names() {
    [ -d "${run_path}/plugins" ] || return 0
    local d
    find "${run_path}/plugins" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r d; do
        [ -f "${d}/plugin.conf" ] || continue
        basename "${d}"
    done
}

# 产物完整性: 清单文件与镜像数据包齐全
function _plugin_built() {
    local dir=$1 f
    [ -d "${dir}/manifests" ] && [ -f "${dir}/images/registry.tar" ] || return 1
    for f in "${plugin_manifests[@]}"; do
        [ -f "${dir}/manifests/${f}" ] || return 1
    done
}

# 加载插件元数据与钩子, 校验产物; 软模式下失败仅返回非零
function plugin_load() {
    local name=$1
    [[ "${name}" =~ ^[a-z0-9_-]+$ ]] || { _plugin_fail "invalid plugin name: ${name}" || return 1; return 1; }

    plugin_dir="${run_path}/plugins/${name}"
    [ -d "${plugin_dir}" ] || { _plugin_fail "plugin '${name}' not found, copy its tgz to deploy dir and extract" || return 1; return 1; }
    [ -f "${plugin_dir}/plugin.conf" ] || { _plugin_fail "${plugin_dir}/plugin.conf not found" || return 1; return 1; }

    # shellcheck disable=SC1090
    source "${plugin_dir}/plugin.conf"
    [ "${plugin_name:-}" == "${name}" ] || { _plugin_fail "plugin.conf name mismatch: expect ${name}, got ${plugin_name:-<empty>}" || return 1; return 1; }
    [ -n "${plugin_version:-}" ] || { _plugin_fail "plugin_version empty in ${plugin_dir}/plugin.conf" || return 1; return 1; }
    [ -n "${plugin_namespace:-}" ] || { _plugin_fail "plugin_namespace empty in ${plugin_dir}/plugin.conf" || return 1; return 1; }
    [ ${#plugin_manifests[@]} -gt 0 ] 2>/dev/null || { _plugin_fail "plugin_manifests empty in ${plugin_dir}/plugin.conf" || return 1; return 1; }

    _plugin_built "${plugin_dir}" || { _plugin_fail "plugin '${name}' artifacts incomplete (manifests/ or images/registry.tar missing), rebuild the plugin package" || return 1; return 1; }

    if [ -f "${plugin_dir}/hooks.sh" ]; then
        # shellcheck disable=SC1090
        source "${plugin_dir}/hooks.sh"
    fi
}

function _plugin_fail() {
    if [ "${_plugin_soft:-0}" == "1" ]; then
        warn "$1"
        return 1
    fi
    error "$1"
}

function plugin_check_cluster() {
    [ -f "${run_path}/admin.kubeconfig" ] || { _plugin_fail "${run_path}/admin.kubeconfig not found, deploy the cluster first" || return 1; return 1; }
    plugin_kubectl get ns default --request-timeout=10s >/dev/null 2>&1 || { _plugin_fail "apiserver unreachable, deploy the cluster first" || return 1; return 1; }
}

# 查询 namespace 上的插件安装注解; 集群不可达时输出空
function _plugin_installed_version() {
    local ns=$1 name=$2
    plugin_kubectl get ns "${ns}" -o 'jsonpath={.metadata.annotations.k8s-deploy\.plugin/'"${name}"'}' 2>/dev/null
}

function plugin_list() {
    local names name dir built installed
    names=$(_plugin_list_names)
    if [ -z "${names}" ]; then
        note "no plugin found, copy plugin tgz to deploy dir and extract (tar xzf plugin-*.tgz)"
        return 0
    fi

    printf '%-14s %-12s %-16s %-18s %s\n' "NAME" "VERSION" "NAMESPACE" "STATE" "DESCRIPTION"
    while IFS= read -r name; do
        [ -z "${name}" ] && continue
        dir="${run_path}/plugins/${name}"
        (
            # shellcheck disable=SC1090
            source "${dir}/plugin.conf"
            built="built"
            if [ ! -d "${dir}/manifests" ] || [ ! -f "${dir}/images/registry.tar" ]; then built="not-built"; fi
            state="${built}"
            if [ "${built}" == "built" ] && [ -f "${run_path}/admin.kubeconfig" ]; then
                installed=$(plugin_kubectl get ns "${plugin_namespace}" --request-timeout=10s \
                    -o 'jsonpath={.metadata.annotations.k8s-deploy\.plugin/'"${name}"'}' 2>/dev/null || true)
                [ -n "${installed}" ] && state="installed(${installed})"
            fi
            printf '%-14s %-12s %-16s %-18s %s\n' "${name}" "${plugin_version:-?}" "${plugin_namespace:-?}" "${state}" "${plugin_description:-}"
        )
    done <<<"${names}"
}

# 插件镜像数据合并进首节点 registry 存储并重启 registry; 以 tar 哈希做戳记, 幂等跳过
function plugin_sync_images() {
    local name=$1 tarball=$2 sum host=${node_ip[0]} remote_tar
    remote_tar="/tmp/plugin-${name}-registry.tar"
    sum=$(sha256sum "${tarball}" | awk '{print $1}')

    if [ -f "${plugin_stamp_dir}/${name}" ] && [ "$(cat "${plugin_stamp_dir}/${name}")" == "${sum}" ]; then
        note "plugin ${name} images already in registry, skip sync"
        return 0
    fi

    h2 "sync plugin ${name} images to registry"
    remote_cp "${tarball}" "${host}:${remote_tar}"
    # nerdctl restart 偶发 containerd 残留 task 报错(file exists), 失败时删除容器
    # 后按标准参数重建
    remote_exec "${host}" "mkdir -p ${registry_data_path} && \
tar xf ${remote_tar} -C ${registry_data_path} --strip-components=1 && rm -f ${remote_tar} && \
/usr/local/bin/nerdctl restart registry || { /usr/local/bin/nerdctl rm -f registry; $(registry_container_cmd); }"

    # registry 重启后等待容器恢复 Running
    remote_exec "${host}" 'for i in $(seq 1 15); do
  /usr/local/bin/nerdctl ps | grep -w registry | grep -q Up && exit 0
  sleep 2
done
echo "registry container not running after restart" >&2
exit 1'

    mkdir -p "${plugin_stamp_dir}"
    printf '%s\n' "${sum}" >"${plugin_stamp_dir}/${name}"
    success "plugin ${name} images synced to registry"
}

function plugin_apply_file() {
    local file=$1
    # 必须 server-side apply: kube-prometheus-stack 的部分 CRD 体积超过 256KB,
    # client-side apply 会因 last-applied-configuration 注解超限被 apiserver 拒绝
    sed -e "s#Placeholder_registry#${registry}#g" "${file}" \
        | plugin_kubectl apply --server-side --force-conflicts -f -
}

# 从清单中提取 CRD 名(metadata 层级的 name)
function _plugin_crd_names() {
    local file=$1
    awk '
        /^---[[:space:]]*$/ { inc=0; got=0; next }
        /^kind:[[:space:]]*CustomResourceDefinition[[:space:]]*$/ { inc=1 }
        # 仅取每个 CRD 文档中 metadata 层级(恰好 2 空格缩进)的第一个 name,
        # 避开 openAPIV3Schema 内大量更深缩进的 name 属性
        inc && !got && /^  name:/ { if ($2 != "") { print $2; got=1 } }
    ' "${file}"
}

# 从 CRD 清单中提取 metadata.name 并等待 Established
function plugin_wait_crds() {
    local file=$1 crds=() n
    while IFS= read -r n; do
        [ -n "${n}" ] && crds+=("crd/${n}")
    done < <(_plugin_crd_names "${file}")

    [ ${#crds[@]} -eq 0 ] && return 0
    info "waiting for ${#crds[@]} CRDs Established"
    if ! plugin_kubectl wait --for=condition=Established --timeout=180s "${crds[@]}"; then
        plugin_kubectl get crd
        _plugin_fail "CRDs not all Established"
    fi
}

# 就绪检查: 有 Pod 且全部容器就绪; 镜像拉取错误(rc=2)立即终止, 其余继续等待
function _plugin_pods_ready() {
    local ns=$1 out reasons bad
    out=$(plugin_kubectl -n "${ns}" get po --no-headers 2>/dev/null) || return 1
    [ -n "${out}" ] || return 1

    reasons=$(plugin_kubectl -n "${ns}" get po \
        -o 'jsonpath={range .items[*]}{range .status.containerStatuses[*]}{.state.waiting.reason}{"\n"}{end}{end}' 2>/dev/null || true)
    if echo "${reasons}" | grep -Eq 'ImagePull|ErrImage'; then
        bad=$(echo "${reasons}" | grep -E 'ImagePull|ErrImage' | sort -u | tr '\n' ' ')
        warn "image pull error in namespace ${ns}: ${bad}"
        return 2
    fi

    echo "${out}" | awk '{
        split($2,a,"/")
        if (a[1]!=a[2] || ($3!="Running" && $3!="Succeeded")) bad++
    } END {exit (bad+0==0 ? 0 : 1)}'
}

function _plugin_dump_ns() {
    local ns=$1
    plugin_kubectl -n "${ns}" get po 2>/dev/null || true
    plugin_kubectl -n "${ns}" get pvc 2>/dev/null || true
    plugin_kubectl -n "${ns}" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 30 || true
}

function plugin_wait_pods() {
    local ns=$1 max=60 interval=10 attempt=1 rc
    h2 "waiting pods ready in namespace ${ns}"
    while true; do
        if _plugin_pods_ready "${ns}"; then
            success "all pods ready in ${ns}"
            return 0
        fi
        rc=$?
        if [ ${rc} -eq 2 ]; then
            _plugin_dump_ns "${ns}"
            _plugin_fail "plugin pods failed to start in ${ns}"
            return 1
        fi
        if [ ${attempt} -ge ${max} ]; then
            warn "timeout after ${max} attempts (${interval}s each)"
            _plugin_dump_ns "${ns}"
            _plugin_fail "plugin pods not ready in ${ns}"
            return 1
        fi
        sleep "${interval}"
        attempt=$((attempt + 1))
    done
}

function plugin_action_install() {
    local name=$1
    plugin_load "${name}" || return 1
    plugin_check_cluster || return 1

    # 安装前自定义校验(如与已装插件互斥), 失败即中止安装
    if declare -F plugin_pre_install >/dev/null 2>&1; then
        plugin_pre_install || return 1
    fi

    h1 "install plugin ${name} (${plugin_version})"
    plugin_sync_images "${name}" "${plugin_dir}/images/registry.tar"

    plugin_kubectl create ns "${plugin_namespace}" 2>/dev/null || true
    success "namespace ${plugin_namespace} ready"

    local f
    for f in "${plugin_manifests[@]}"; do
        h2 "apply ${f}"
        plugin_apply_file "${plugin_dir}/manifests/${f}"
        if grep -Eq '^kind:[[:space:]]*CustomResourceDefinition[[:space:]]*$' "${plugin_dir}/manifests/${f}"; then
            plugin_wait_crds "${plugin_dir}/manifests/${f}" || return 1
        fi
    done

    plugin_wait_pods "${plugin_namespace}" || return 1

    if declare -F plugin_ready >/dev/null 2>&1; then
        plugin_ready || _plugin_fail "plugin ${name} custom readiness check failed"
    fi

    plugin_kubectl annotate ns "${plugin_namespace}" \
        "k8s-deploy.plugin/${name}=${plugin_version}" --overwrite >/dev/null
    success "plugin ${name} marked installed"

    if declare -F plugin_post_install >/dev/null 2>&1; then
        plugin_post_install
    fi
    success "plugin ${name} installed"
}

function plugin_action_status() {
    local name=$1
    plugin_load "${name}" || return 1
    plugin_check_cluster || return 1
    h1 "plugin ${name} status"
    local installed
    installed=$(_plugin_installed_version "${plugin_namespace}" "${name}")
    if [ -z "${installed}" ]; then
        warn "plugin ${name} not installed (namespace ${plugin_namespace} has no install annotation)"
    else
        info "installed version: ${installed}"
    fi
    plugin_kubectl -n "${plugin_namespace}" get po
    plugin_kubectl -n "${plugin_namespace}" get pvc 2>/dev/null || true
}

# CRD 删除为异步且批量 delete 单次调用可能部分失败, 逐个确认消失;
# 长时间不消失时清 finalizer 兜底(仅告警不中断, 兼容软模式)
function plugin_wait_crds_gone() {
    local file=$1 crds=() n attempt=1
    while IFS= read -r n; do
        [ -n "${n}" ] && crds+=("${n}")
    done < <(_plugin_crd_names "${file}")
    [ ${#crds[@]} -eq 0 ] && return 0

    local left
    while [ ${attempt} -le 24 ]; do
        left=()
        for n in "${crds[@]}"; do
            plugin_kubectl get crd "${n}" >/dev/null 2>&1 && left+=("${n}")
        done
        [ ${#left[@]} -eq 0 ] && return 0
        # 首轮等待后重删一次, 补救批量 delete 中被吞掉的漏网项
        if [ ${attempt} -eq 2 ]; then
            plugin_kubectl delete crd --ignore-not-found --wait=false "${left[@]}" >/dev/null 2>&1 || true
        fi
        sleep 5
        attempt=$((attempt + 1))
    done

    warn "CRDs not gone after delete, clearing finalizers: ${left[*]}"
    for n in "${crds[@]}"; do
        if plugin_kubectl get crd "${n}" >/dev/null 2>&1; then
            plugin_kubectl patch crd "${n}" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        fi
    done
    sleep 5
    return 0
}

# 删除清单后等待 namespace 消失, 卡住时清空 finalizer 兜底
function _plugin_delete_namespace() {
    local ns=$1 attempt=1
    plugin_kubectl delete ns "${ns}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    while [ ${attempt} -le 36 ]; do
        if ! plugin_kubectl get ns "${ns}" >/dev/null 2>&1; then
            success "namespace ${ns} deleted"
            return 0
        fi
        sleep 5
        attempt=$((attempt + 1))
    done

    warn "namespace ${ns} stuck terminating, clearing finalizers"
    plugin_kubectl -n "${ns}" get po -o name 2>/dev/null | while IFS= read -r p; do
        plugin_kubectl -n "${ns}" patch "${p}" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    done
    plugin_kubectl patch ns "${ns}" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    sleep 5
    if plugin_kubectl get ns "${ns}" >/dev/null 2>&1; then
        _plugin_fail "namespace ${ns} still terminating after finalizer cleanup" || return 1
        return 1
    fi
    return 0
}

function plugin_action_remove() {
    local name=$1
    plugin_load "${name}" || return 1
    plugin_check_cluster || return 1

    h1 "remove plugin ${name} (${plugin_version})"

    if declare -F plugin_pre_remove >/dev/null 2>&1; then
        plugin_pre_remove || warn "plugin ${name} pre-remove hook failed, continue"
    fi

    # 逆序删除: 普通资源先删, CRD 最后删
    local i f
    for ((i = ${#plugin_manifests[@]} - 1; i >= 0; i--)); do
        f=${plugin_manifests[${i}]}
        h2 "delete ${f}"
        sed -e "s#Placeholder_registry#${registry}#g" "${plugin_dir}/manifests/${f}" \
            | plugin_kubectl delete --ignore-not-found --wait=false -f - 2>/dev/null || true
    done

    _plugin_delete_namespace "${plugin_namespace}" || return 1

    # CRD 为异步删除且批量 delete 可能漏删, 逐个确认消失
    local cf
    for cf in "${plugin_manifests[@]}"; do
        grep -Eq '^kind:[[:space:]]*CustomResourceDefinition[[:space:]]*$' "${plugin_dir}/manifests/${cf}" || continue
        plugin_wait_crds_gone "${plugin_dir}/manifests/${cf}"
    done

    rm -f "${plugin_stamp_dir}/${name}"
    success "plugin ${name} removed"
}

# 卸载集群前 best-effort 清理所有已解压插件(子 shell 隔离, 互不影响)
function plugins_remove_all() {
    [ -f "${run_path}/admin.kubeconfig" ] || { note "no admin.kubeconfig, skip plugin removal"; return 0; }
    local names name
    names=$(_plugin_list_names)
    [ -n "${names}" ] || return 0
    h1 "remove plugins before cluster uninstall"
    while IFS= read -r name; do
        [ -z "${name}" ] && continue
        (
            _plugin_soft=1
            plugin_action_remove "${name}"
        ) || warn "remove plugin ${name} failed, continue with uninstall"
    done <<<"${names}"
}

function plugin_main() {
    local action=${1:-} name=${2:-}
    case "${action}" in
    list)
        plugin_list
        ;;
    install)
        [ -n "${name}" ] || { plugin_usage; error "install requires a plugin name"; }
        plugin_action_install "${name}"
        ;;
    remove)
        [ -n "${name}" ] || { plugin_usage; error "remove requires a plugin name"; }
        plugin_action_remove "${name}"
        ;;
    status)
        if [ -n "${name}" ]; then
            plugin_action_status "${name}"
        else
            plugin_list
        fi
        ;;
    *)
        plugin_usage
        [ -n "${action}" ] && error "unknown plugin command: ${action}"
        ;;
    esac
}
