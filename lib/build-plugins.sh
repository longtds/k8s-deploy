# shellcheck shell=bash
# ---------------------------------------------------------------------------
# 可选插件构建(仅构建机执行, 不进入部署包)
#
# 流程: helm 拉取/渲染 chart -> 按 YAML document 拆分 CRD -> 通用镜像改写
#       (Placeholder_registry/k8s/<短名>:<tag>) -> 逐镜像拉取并推入独立临时
#       registry -> registry 存储打包为 plugins/<name>/images/registry.tar
#       -> 组装并打 target/plugin-<name>-v<版本>-<日期>-<arch>.tgz
#
# 新增插件(引擎零改动):
#   1. 新建 plugins/<name>/ 下 plugin.conf / hooks.sh / values.yaml
#   2. config.ini 增加 chart 版本与仓库变量
#   3. make_plugins 的 case 中登记对应的 _build_plugin_<name> 渲染参数
# ---------------------------------------------------------------------------

# 路径依赖 load_config 设置的 build_path, 在 make_plugins 入口初始化
# (本文件在 build.sh 启动时即被 source, 彼时 build_path 尚为空)
plugin_reg_port=5002

function init_plugin_paths() {
    plugin_work_path=${build_path}/plugins
    plugin_chart_path=${build_path}/charts
    plugin_render_path=${build_path}/plugin-render
    plugin_store_path=${build_path}/plugin-registry
    helm_dir=${build_path}/helm
    helm_home=${build_path}/helm-home
    helm_bin=${helm_dir}/helm
}

# helm 配置/cache 全部隔离在 build 目录, 不污染构建机 ~/.config/helm
function _helm() {
    HELM_CONFIG_HOME=${helm_home}/config \
        HELM_CACHE_HOME=${helm_home}/cache \
        HELM_DATA_HOME=${helm_home}/data \
        "${helm_bin}" "$@"
}

# helm 仅为构建机工具(跟随构建机架构), 不进入任何离线包
function ensure_helm() {
    h2 "ensure helm"
    local helm_pkg="helm-v${helm_version}-linux-${host_arch}.tar.gz"
    local helm_url="https://get.helm.sh/${helm_pkg}"

    if [ -x "${helm_bin}" ] && cache_valid "helm-bin" "${helm_bin}" "${helm_version}" "${host_arch}"; then
        note "helm exists"
        return 0
    fi

    download "${helm_url}" "${helm_pkg}"
    mkdir -p "${helm_dir}"
    if tar xf "${download_path}/${helm_pkg}" -C "${helm_dir}" --strip-components=1 "linux-${host_arch}/helm"; then
        cache_commit "helm-bin" "${helm_version}" "${host_arch}"
        success "helm ${helm_version} ready"
    else
        error "extract helm failed"
    fi
}

function setup_helm_repos() {
    _helm repo add prometheus-community "${prometheus_chart_repo}" --force-update
    _helm repo add grafana "${loki_chart_repo}" --force-update
    _helm repo add istio "${istio_chart_repo}" --force-update
    _helm repo add higress.io "${higress_chart_repo}" --force-update
    _helm repo update prometheus-community grafana istio higress.io
}

# 拉取并解压 chart(版本戳缓存)
function pull_chart() {
    local repo_chart=$1 version=$2 expect_dir=$3
    if [ -f "${expect_dir}/Chart.yaml" ] && cache_valid "chart-${expect_dir##*/}" "${expect_dir}/Chart.yaml" "${version}"; then
        note "chart ${repo_chart} ${version} exists"
        return 0
    fi
    rm -rf "${expect_dir}"
    mkdir -p "${plugin_chart_path}"
    if _helm pull "${repo_chart}" --version "${version}" --untar --untardir "${plugin_chart_path}"; then
        cache_commit "chart-${expect_dir##*/}" "${version}"
        success "pulled chart ${repo_chart} ${version}"
    else
        error "pull chart ${repo_chart} ${version} failed"
    fi
}

# 渲染 chart 到单个 yaml
function render_chart() {
    local release=$1 chart_dir=$2 namespace=$3 values=$4 out=$5
    if _helm template "${release}" "${chart_dir}" --namespace "${namespace}" \
        --include-crds --values "${values}" >"${out}"; then
        success "rendered ${release} -> ${out}"
    else
        rm -f "${out}"
        error "helm template ${release} failed (check values.yaml against chart version)"
    fi
}

# 按 YAML document 将 CRD 拆到 crds 文件, 其余进 rest 文件, 保持 document 分隔符;
# helm test hook 文档(镜像仅测试用)直接丢弃
function split_crds() {
    local src=$1 crds=$2 rest=$3
    rm -f "${crds}" "${rest}"
    : >"${crds}"
    : >"${rest}"
    awk -v crds="${crds}" -v rest="${rest}" '
        function emit() {
            if (doc == "") return
            if (istest) { doc=""; iscrd=0; istest=0; return }
            out = iscrd ? crds : rest
            if (cnt[out]++ > 0) print "---" > out
            print doc > out
            doc = ""; iscrd = 0; istest = 0
        }
        /^---[[:space:]]*$/ { emit(); next }
        { doc = (doc == "" ? $0 : doc "\n" $0) }
        /^kind:[[:space:]]*CustomResourceDefinition[[:space:]]*$/ { iscrd = 1 }
        /helm\.sh\/hook"?[[:space:]]*:[[:space:]]*test/ { istest = 1 }
        END { emit() }
    ' "${src}"
}

# 提取镜像引用(两类):
#   1. image: 标量行(必须有非空值, CRD openAPIV3Schema 中的 image: 属性行为空需排除)
#   2. --flag=<镜像> 形式的 operator 启动参数(如 --prometheus-config-reloader=...)
# 最终过滤: 仅保留严格镜像引用形态, 排除 CRD 描述中的 helm 模板串({{ .ProxyImage }})
# 与 auto 等占位值
function plugin_extract_images() {
    local yaml_file=$1
    {
        grep -E '^[[:space:]]*image:[[:space:]]*[^[:space:]]' "${yaml_file}" \
            | sed -e 's/^[[:space:]]*image:[[:space:]]*//'
        grep -oE -- '--[a-z-]+=[a-z0-9.-]+[.:0-9]*/[a-zA-Z0-9._/-]+:[a-zA-Z0-9._-]+' "${yaml_file}" \
            | sed -e 's/^--[a-z-]*=//'
    } | sed -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" \
        | grep -E '^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._/-]+)*:[a-zA-Z0-9._-]+$' \
        | sort -u
}

# 由渲染文件的 image: 行生成 原始引用<TAB>本地引用 映射, 校验短名碰撞与 digest-only 引用
function build_image_map() {
    local map=$1
    shift
    local f
    for f in "$@"; do plugin_extract_images "${f}"; done | while IFS= read -r img; do
        local stripped name tag
        stripped=${img%%@*}
        name=${stripped##*/}
        case "${name}" in
        *:*)
            tag=${name#*:}
            name=${name%%:*}
            ;;
        *)
            name="__NO_TAG__"
            tag=""
            ;;
        esac
        printf '%s\t%s:%s\n' "${img}" "${name}" "${tag}"
    done >"${map}"

    if awk -F'\t' '
        $2 == "__NO_TAG__:" { print "image without tag (digest-only) unsupported: " $1 > "/dev/stderr"; bad=1 }
        { if (($2 in seen) && seen[$2] != $1) { print "image short-name collision for " $2 ": " seen[$2] " vs " $1 > "/dev/stderr"; bad=1 } seen[$2]=$1 }
        END { exit bad+0 }
    ' "${map}"; then
        # 映射文件中补全为最终本地引用
        local tmp=${map}.tmp
        awk -F'\t' '{print $1 "\tPlaceholder_registry/k8s/" $2}' "${map}" >"${tmp}"
        mv "${tmp}" "${map}"
        success "image map built ($(wc -l <"${map}") images)"
    else
        rm -f "${map}"
        error "image map validation failed"
    fi
}

# 用映射表对渲染文件做固定字符串替换
function rewrite_images() {
    local map=$1
    shift
    local orig localimg po pl
    while IFS=$'\t' read -r orig localimg; do
        [ -z "${orig}" ] && continue
        po=$(printf '%s' "${orig}" | sed 's/[.[*#^$\\]/\\&/g')
        pl=$(printf '%s' "${localimg}" | sed 's/[\\&]/\\&/g')
        sed -i "s#${po}#${pl}#g" "$@"
    done <"${map}"

    local leftover
    leftover=$(for f in "$@"; do plugin_extract_images "${f}"; done | sort -u | grep -v '^Placeholder_registry/' || true)
    if [ -n "${leftover}" ]; then
        error "images not rewritten to local registry:
${leftover}"
    fi
    success "all images rewritten to Placeholder_registry"
}

# 逐镜像拉取(目标架构) -> 推入该插件独占的临时 registry -> 打包 registry 存储数据
# 产物布局 registry/{blobs,repositories}/..., 部署期 tar --strip-components=1 合并进
# /var/lib/registry, 与核心镜像包一致
function bundle_plugin_images() {
    local name=$1 map=$2 out_tar=$3
    local parent=${plugin_store_path}/${name}
    local regdir=${parent}/registry

    image_rm -f plugin-registry 2>/dev/null || true

    local build_reg_image="k8s-deploy-registry:${registry_version}"
    if ! ${CONTAINER_CLI} inspect "${build_reg_image}" >/dev/null 2>&1; then
        local build_reg_src=${registry_image}
        if [ -n "${registry_proxy}" ]; then build_reg_src=${registry_proxy}/${registry_image}; fi
        image_pull "${build_reg_src}" "linux/${host_arch}"
        image_tag "${build_reg_src}" "${build_reg_image}"
    fi

    # 上次构建的 registry 容器以 root 写入 blob, 宿主普通用户无权删除,
    # 借用同一 registry 镜像(含 sh)在容器内清理后再重建
    mkdir -p "${parent}"
    if ! image_run --rm -v "${parent}:/target" "${build_reg_image}" \
        sh -c 'rm -rf /target/registry'; then
        error "clean old plugin registry storage failed"
    fi
    mkdir -p "${regdir}"

    if image_run -d --name plugin-registry -p "${plugin_reg_port}:5000" \
        -v "${regdir}:/var/lib/registry" "${build_reg_image}"; then
        success "temp plugin registry started"
        sleep 5

        local orig localimg dst
        while IFS=$'\t' read -r orig localimg; do
            dst=${localimg/#Placeholder_registry/127.0.0.1:${plugin_reg_port}}
            sync_image "${orig}" "${dst}"
            success "bundled ${orig} -> ${dst}"
        done <"${map}"
    else
        image_rm -f plugin-registry 2>/dev/null || true
        error "start temp plugin registry failed"
    fi

    image_rm -f plugin-registry 2>/dev/null || true
    sync

    if tar -C "${parent}" -cf "${out_tar}" registry; then
        success "plugin ${name} image bundle ready"
    else
        rm -f "${out_tar}"
        error "pack plugin ${name} registry data failed"
    fi
}

# 组装插件目录(conf/hooks/manifests/images)并打独立 tgz
function package_plugin() {
    local name=$1 version=$2
    local target=${target_path}/plugin-${name}-v${version}-$(date +%Y%m%d)-${arch_name}.tgz
    rm -f "${target}"
    if tar -C "${plugin_work_path}" --transform "s,^${name}/,plugins/${name}/," \
        -zcf "${target}" "${name}"; then
        success "make target ${target}"
        echo "${target}"
    else
        error "make plugin ${name} target failed"
    fi
}

# 渲染与镜像打包完成后的公共收尾: 写入版本 -> 打包 -> 提交缓存戳(key 需与各构建
# 函数 cache_valid 使用的字符串一致)
function finish_plugin() {
    local name=$1 version=$2 key=$3
    local src_dir=${root_path}/plugins/${name}
    local pdst=${plugin_work_path}/${name}
    sed "s/__PLUGIN_VERSION__/${version}/" "${src_dir}/plugin.conf" >"${pdst}/plugin.conf"
    cp "${src_dir}/hooks.sh" "${pdst}/hooks.sh"
    package_plugin "${name}" "${version}" >/dev/null
    cache_commit "plugin-${name}" "${key}"
}

# ---------------------------------------------------------------------------
# prometheus: kube-prometheus-stack
# ---------------------------------------------------------------------------
function build_plugin_prometheus() {
    h2 "plugin prometheus (kube-prometheus-stack ${prometheus_stack_version})"
    local name=prometheus version=${prometheus_stack_version}
    local src_dir=${root_path}/plugins/${name}
    local pdst=${plugin_work_path}/${name}
    local target=${target_path}/plugin-${name}-v${version}-$(date +%Y%m%d)-${arch_name}.tgz

    local values_hash src_hash
    values_hash=$(sha256sum "${src_dir}/values.yaml" | awk '{print $1}')
    src_hash=$({ sha256sum "${src_dir}/plugin.conf" "${src_dir}/hooks.sh"; } | sha256sum | awk '{print $1}')
    if [ -f "${target}" ] && cache_valid "plugin-${name}" "${target}" \
        "${version}|${values_hash}|${src_hash}|${arch_name}"; then
        note "${target} exists"
        return 0
    fi

    local chart_dir=${plugin_chart_path}/kube-prometheus-stack
    pull_chart "prometheus-community/kube-prometheus-stack" "${version}" "${chart_dir}"

    rm -rf "${pdst}" "${plugin_render_path}/${name}"
    mkdir -p "${pdst}/manifests" "${pdst}/images" "${plugin_render_path}/${name}"
    local rendered=${plugin_render_path}/${name}/rendered.yaml
    render_chart kps "${chart_dir}" monitoring "${src_dir}/values.yaml" "${rendered}"

    split_crds "${rendered}" "${pdst}/manifests/00-crds.yaml" "${pdst}/manifests/10-stack.yaml"
    local map=${plugin_render_path}/${name}/image.map
    build_image_map "${map}" "${pdst}/manifests/00-crds.yaml" "${pdst}/manifests/10-stack.yaml"
    rewrite_images "${map}" "${pdst}/manifests/00-crds.yaml" "${pdst}/manifests/10-stack.yaml"

    bundle_plugin_images "${name}" "${map}" "${pdst}/images/registry.tar"

    finish_plugin "${name}" "${version}" "${version}|${values_hash}|${src_hash}|${arch_name}"
}

# ---------------------------------------------------------------------------
# loki: loki-stack(promtail + loki 单体), 无 CRD
# ---------------------------------------------------------------------------
function build_plugin_loki() {
    h2 "plugin loki (loki-stack ${loki_stack_version})"
    local name=loki version=${loki_stack_version}
    local src_dir=${root_path}/plugins/${name}
    local pdst=${plugin_work_path}/${name}
    local target=${target_path}/plugin-${name}-v${version}-$(date +%Y%m%d)-${arch_name}.tgz

    local values_hash src_hash
    values_hash=$(sha256sum "${src_dir}/values.yaml" | awk '{print $1}')
    src_hash=$({ sha256sum "${src_dir}/plugin.conf" "${src_dir}/hooks.sh"; } | sha256sum | awk '{print $1}')
    if [ -f "${target}" ] && cache_valid "plugin-${name}" "${target}" \
        "${version}|${values_hash}|${src_hash}|${arch_name}"; then
        note "${target} exists"
        return 0
    fi

    local chart_dir=${plugin_chart_path}/loki-stack
    pull_chart "grafana/loki-stack" "${version}" "${chart_dir}"

    rm -rf "${pdst}" "${plugin_render_path}/${name}"
    mkdir -p "${pdst}/manifests" "${pdst}/images" "${plugin_render_path}/${name}"
    local rendered=${plugin_render_path}/${name}/rendered.yaml
    render_chart loki "${chart_dir}" logging "${src_dir}/values.yaml" "${rendered}"

    split_crds "${rendered}" "${plugin_render_path}/${name}/discard-crds.yaml" "${pdst}/manifests/10-loki.yaml"
    local map=${plugin_render_path}/${name}/image.map
    build_image_map "${map}" "${pdst}/manifests/10-loki.yaml"
    rewrite_images "${map}" "${pdst}/manifests/10-loki.yaml"

    bundle_plugin_images "${name}" "${map}" "${pdst}/images/registry.tar"

    finish_plugin "${name}" "${version}" "${version}|${values_hash}|${src_hash}|${arch_name}"
}

# ---------------------------------------------------------------------------
# istio: base(CRD) + istiod + ingress gateway, 多 chart 按序渲染拆分
# ---------------------------------------------------------------------------
function build_plugin_istio() {
    h2 "plugin istio (base/istiod/gateway ${istio_version})"
    local name=istio version=${istio_version}
    local src_dir=${root_path}/plugins/${name}
    local pdst=${plugin_work_path}/${name}
    local target=${target_path}/plugin-${name}-v${version}-$(date +%Y%m%d)-${arch_name}.tgz

    local values_hash src_hash gw_hash
    values_hash=$(sha256sum "${src_dir}/values.yaml" | awk '{print $1}')
    src_hash=$({ sha256sum "${src_dir}/plugin.conf" "${src_dir}/hooks.sh"; } | sha256sum | awk '{print $1}')
    gw_hash=$(sha256sum "${src_dir}/values-gateway.yaml" | awk '{print $1}')
    if [ -f "${target}" ] && cache_valid "plugin-${name}" "${target}" \
        "${version}|${values_hash}|${src_hash}|${arch_name}|${gw_hash}"; then
        note "${target} exists"
        return 0
    fi

    local render_dir=${plugin_render_path}/${name}
    rm -rf "${pdst}" "${render_dir}"
    mkdir -p "${pdst}/manifests" "${pdst}/images" "${render_dir}"

    local chart
    for chart in base istiod gateway; do
        pull_chart "istio/${chart}" "${version}" "${plugin_chart_path}/${chart}"
    done
    render_chart istio-base "${plugin_chart_path}/base" istio-system "${src_dir}/values.yaml" "${render_dir}/base.yaml"
    render_chart istiod "${plugin_chart_path}/istiod" istio-system "${src_dir}/values.yaml" "${render_dir}/istiod.yaml"
    # gateway chart values schema 严格, 使用专属 values 文件
    render_chart istio-ingressgateway "${plugin_chart_path}/gateway" istio-system "${src_dir}/values-gateway.yaml" "${render_dir}/gateway.yaml"

    # base 拆出 CRD, 其余 chart 拆分仅为去掉文档间冗余分隔
    split_crds "${render_dir}/base.yaml" "${pdst}/manifests/00-crds.yaml" "${pdst}/manifests/10-base.yaml"
    split_crds "${render_dir}/istiod.yaml" "${render_dir}/discard-crds.yaml" "${pdst}/manifests/11-istiod.yaml"
    split_crds "${render_dir}/gateway.yaml" "${render_dir}/discard-crds2.yaml" "${pdst}/manifests/12-gateway.yaml"

    local map=${render_dir}/image.map
    build_image_map "${map}" "${pdst}/manifests/00-crds.yaml" "${pdst}/manifests/10-base.yaml" \
        "${pdst}/manifests/11-istiod.yaml" "${pdst}/manifests/12-gateway.yaml"
    rewrite_images "${map}" "${pdst}/manifests/00-crds.yaml" "${pdst}/manifests/10-base.yaml" \
        "${pdst}/manifests/11-istiod.yaml" "${pdst}/manifests/12-gateway.yaml"

    # sidecar 注入模板按 hub/image/tag 分字段存储镜像, 通用 image: 行改写覆盖不到,
    # 单独整体替换 hub, 运行时拼接 Placeholder_registry/k8s/proxyv2:<tag> 与约定一致
    local mf
    for mf in "${pdst}/manifests/00-crds.yaml" "${pdst}/manifests/10-base.yaml" \
        "${pdst}/manifests/11-istiod.yaml" "${pdst}/manifests/12-gateway.yaml"; do
        sed -i 's#docker\.io/istio#Placeholder_registry/k8s#g' "${mf}"
    done
    if grep -rq 'docker\.io/istio' "${pdst}/manifests"; then
        error "istio upstream registry leftover in manifests"
    fi
    success "istio hub rewritten to Placeholder_registry"

    # gateway Deployment 与被注入 sidecar 的 proxyv2 镜像由 mutating webhook 在运行时
    # 按注入配置的 hub/image/tag 拼接(清单中为 image: auto 字面量), 清单改写覆盖不到,
    # 显式并入打包清单
    printf '%s\t%s\n' "docker.io/istio/proxyv2:${version}" "Placeholder_registry/k8s/proxyv2:${version}" >>"${map}"

    bundle_plugin_images "${name}" "${map}" "${pdst}/images/registry.tar"

    finish_plugin "${name}" "${version}" "${version}|${values_hash}|${src_hash}|${arch_name}|${gw_hash}"
}

# ---------------------------------------------------------------------------
# higress: 云原生网关(higress-core + higress-console umbrella chart)
# ---------------------------------------------------------------------------
function build_plugin_higress() {
    h2 "plugin higress (higress ${higress_version})"
    local name=higress version=${higress_version}
    local src_dir=${root_path}/plugins/${name}
    local pdst=${plugin_work_path}/${name}
    local target=${target_path}/plugin-${name}-v${version}-$(date +%Y%m%d)-${arch_name}.tgz

    local values_hash src_hash
    values_hash=$(sha256sum "${src_dir}/values.yaml" | awk '{print $1}')
    src_hash=$({ sha256sum "${src_dir}/plugin.conf" "${src_dir}/hooks.sh"; } | sha256sum | awk '{print $1}')
    if [ -f "${target}" ] && cache_valid "plugin-${name}" "${target}" \
        "${version}|${values_hash}|${src_hash}|${arch_name}"; then
        note "${target} exists"
        return 0
    fi

    # 父 chart 已内嵌子 chart(higress-core/higress-console), 拉取即为完整树
    local chart_dir=${plugin_chart_path}/higress
    pull_chart "higress.io/higress" "${version}" "${chart_dir}"

    rm -rf "${pdst}" "${plugin_render_path}/${name}"
    mkdir -p "${pdst}/manifests" "${pdst}/images" "${plugin_render_path}/${name}"
    local rendered=${plugin_render_path}/${name}/rendered.yaml
    render_chart higress "${chart_dir}" higress-system "${src_dir}/values.yaml" "${rendered}"

    split_crds "${rendered}" "${pdst}/manifests/00-crds.yaml" "${pdst}/manifests/10-higress.yaml"
    local map=${plugin_render_path}/${name}/image.map
    build_image_map "${map}" "${pdst}/manifests/00-crds.yaml" "${pdst}/manifests/10-higress.yaml"
    rewrite_images "${map}" "${pdst}/manifests/00-crds.yaml" "${pdst}/manifests/10-higress.yaml"

    bundle_plugin_images "${name}" "${map}" "${pdst}/images/registry.tar"

    finish_plugin "${name}" "${version}" "${version}|${values_hash}|${src_hash}|${arch_name}"
}

function make_plugins() {
    h1 "make optional plugins"
    init_plugin_paths

    if [ ${#build_plugins[@]} -eq 0 ]; then
        note "build_plugins is empty, skip plugin packages"
        return 0
    fi

    ensure_helm
    setup_helm_repos

    local name
    for name in "${build_plugins[@]}"; do
        case "${name}" in
        prometheus)
            build_plugin_prometheus
            ;;
        loki)
            build_plugin_loki
            ;;
        istio)
            build_plugin_istio
            ;;
        higress)
            build_plugin_higress
            ;;
        *)
            error "unknown plugin in build_plugins: ${name}"
            ;;
        esac
    done
}
