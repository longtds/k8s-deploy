# shellcheck shell=bash

function usage() {
    echo "Usage: $0 [x86_64|aarch64|all ...]"
    echo "  无参数: 构建config.ini中arch指定的架构"
    echo "  x86_64: 构建x86_64独立安装包"
    echo "  aarch64: 构建aarch64独立安装包"
    echo "  all: 依次构建所有架构的独立安装包"
    exit 1
}

function host_arch_name() {
    case $(uname -m) in
    x86_64)
        echo amd64
        ;;
    aarch64 | arm64)
        echo arm64
        ;;
    *)
        error "unsupported host arch $(uname -m)"
        ;;
    esac
}

function load_config() {
    arch=$1
    cd ${root_path}
    source config.ini

    download_path=${run_path}/download
    build_path=${run_path}/build/${arch_name}
    pkg_path=${build_path}/pkg
    registry_path=${build_path}/registry
    target_path=${run_path}/target

    mkdir -p ${download_path} ${pkg_path} ${registry_path} ${target_path}
}

# ---------------------------------------------------------------------------
# 构建缓存版本戳:
#   旧逻辑仅以"文件存在"作为跳过条件, config.ini 版本号升级后会复用旧产物。
#   这里为每个产物保存一个由版本号/架构/源哈希构成的键, 键不匹配即重建。
#   戳文件集中在 pkg/.stamps (打包时排除, 不进入离线包)。
# ---------------------------------------------------------------------------
function _cache_key() {
    printf '%s\037' "$@" | sha256sum | awk '{print $1}'
}

function cache_valid() {
    local name=$1 target=$2
    shift 2
    local stamp=${pkg_path}/.stamps/${name}
    [ -f "${target}" ] && [ -f "${stamp}" ] && [ "$(cat "${stamp}")" == "$(_cache_key "$@")" ]
}

function cache_commit() {
    local name=$1
    shift
    mkdir -p "${pkg_path}/.stamps"
    _cache_key "$@" >"${pkg_path}/.stamps/${name}"
}

# ---------------------------------------------------------------------------
# 下载: 重试 + 内容校验 + 可选 sha256 校验
# ---------------------------------------------------------------------------
function download() {
    local file_url="$1"
    local file_name="$2"
    local sha256="${3:-}"

    local out="${download_path}/${file_name}"

    if [ -f "${out}" ]; then
        note "${out} exists"
        return 0
    fi

    note "download ${file_url}"

    # curl 自动遵循 http_proxy/https_proxy 环境变量
    # --retry: 网络错误重试; --fail: HTTP 4xx/5xx 返回非零; -L: 跟随重定向
    if ! curl -fL --retry 3 --retry-delay 5 --retry-max-time 120 \
        --connect-timeout 30 --max-time 600 \
        "${file_url}" -o "${out}"; then
        rm -f "${out}"
        error "download ${file_name} failed"
    fi

    # 最小体积校验: 避免把 HTML 错误页(通常几 KB)当作二进制/压缩包
    local fsize
    fsize=$(stat -c %s "${out}" 2>/dev/null || stat -f %z "${out}" 2>/dev/null || echo 0)
    if [ "${fsize}" -lt 1024 ]; then
        error "download ${file_name} too small (${fsize} bytes), likely an error page"
    fi

    # 可选 sha256 校验
    if [ -n "${sha256}" ]; then
        local actual
        actual=$(sha256sum "${out}" | awk '{print $1}')
        if [ "${actual}" != "${sha256}" ]; then
            rm -f "${out}"
            error "sha256 mismatch for ${file_name}: expected ${sha256}, got ${actual}"
        fi
        success "sha256 verified ${file_name}"
    fi

    success "download ${file_name}"
}

# 下载 sha256 校验文件并提取指定文件的校验和
# 兼容三种格式:
#   1. 仅 hash (kubernetes .sha256)
#   2. "hash  filename" (GNU sha256sum)
#   3. "filename: hash" (部分项目)
function fetch_sha256() {
    local sum_url="$1"
    local file_name="$2"

    local sum_file="${download_path}/.sha256_${file_name}"
    if ! curl -fsSL --retry 2 --retry-delay 3 "${sum_url}" -o "${sum_file}" 2>/dev/null; then
        rm -f "${sum_file}"
        return 0
    fi

    # 格式1: 文件首行就是 64 位 hex hash (如 kubernetes .sha256 单文件格式)
    local first_line
    first_line=$(head -n 1 "${sum_file}" | tr -d '[:space:]')
    if [[ "${first_line}" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "${first_line}"
        return 0
    fi

    # 格式2/3: 在内容中查找 filename 对应的 hash
    # 先按行匹配含文件名的行, 再从行中提取 64 位 hex hash
    grep -F "${file_name}" "${sum_file}" 2>/dev/null \
        | head -n 1 \
        | grep -oE '[0-9a-fA-F]{64}' \
        | head -n 1
}

function download_file() {
    h2 "download_file"
    if [ ! -d ${download_path} ]; then mkdir ${download_path}; fi

    # kubernetes: 获取官方 sha256 校验和
    local k8s_sha256=""
    k8s_sha256=$(fetch_sha256 "${kubernetes_url}.sha256" "${kubernetes_file}")
    download "${kubernetes_url}" "${kubernetes_file}" "${k8s_sha256}"

    # etcd: 从 SHA256SUMS 提取校验和
    local etcd_sha256=""
    etcd_sha256=$(fetch_sha256 "https://github.com/etcd-io/etcd/releases/download/v${etcd_version}/SHA256SUMS" "${etcd_file}")
    download "${etcd_url}" "${etcd_file}" "${etcd_sha256}"

    download "${cfssl_url}" "${cfssl_file}"
    download "${cfssljson_url}" "${cfssljson_file}"
    download "${nerdctl_url}" "${nerdctl_file}"
    download "${localpath_url}" "${localpath_file}"
    download "${coredns_url}" "${coredns_file}.base"
    download "${metrics_url}" "${metrics_file}"
    download "${k9s_url}" "${k9s_file}"
    download "${calico_url}" "${calico_file}"
}

# ---------------------------------------------------------------------------
# 容器运行时抽象: 自动检测 docker / nerdctl, 统一封装镜像操作
# ---------------------------------------------------------------------------
function detect_container_runtime() {
    if command -v docker >/dev/null 2>&1; then
        CONTAINER_CLI=docker
    elif command -v nerdctl >/dev/null 2>&1; then
        CONTAINER_CLI=nerdctl
    else
        error "no container runtime found: install docker or nerdctl"
    fi
    success "use container runtime: ${CONTAINER_CLI}"
}

# 拉取镜像 (支持平台)
function image_pull() {
    local image="$1"
    local platform="${2:-}"
    if [ -n "${platform}" ]; then
        ${CONTAINER_CLI} pull --platform "${platform}" "${image}"
    else
        ${CONTAINER_CLI} pull "${image}"
    fi
}

function image_tag() {
    ${CONTAINER_CLI} tag "$1" "$2"
}

function image_push() {
    ${CONTAINER_CLI} push "$1"
}

# 保存镜像为 tar
function image_save() {
    local image="$1"
    local out="$2"
    ${CONTAINER_CLI} save "${image}" >"${out}"
}

# 加载镜像 tar
function image_load() {
    ${CONTAINER_CLI} load -i "$1"
}

function image_ps() {
    ${CONTAINER_CLI} ps "$@"
}

function image_rm() {
    ${CONTAINER_CLI} rm -f "$@"
}

# 运行容器 (透传参数)
function image_run() {
    ${CONTAINER_CLI} run "$@"
}

function sync_image() {
    local src_image="$1"
    local dst_image="$2"

    if [ -n "${registry_proxy}" ]; then
        src_image=${registry_proxy}/${src_image}
    fi

    if image_pull "${src_image}" "linux/${arch_name}"; then
        image_tag "${src_image}" "${dst_image}"
        if ! image_push "${dst_image}"; then
            error "push ${dst_image} failed"
        fi
    else
        error "pull ${src_image} failed"
    fi
}
