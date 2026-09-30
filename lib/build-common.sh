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

function download_file() {
    h2 "download_file"
    if [ ! -d ${download_path} ]; then mkdir ${download_path}; fi

    download "${cfssl_url}" "${cfssl_file}"
    download "${cfssljson_url}" "${cfssljson_file}"
    download "${etcd_url}" "${etcd_file}"
    download "${nerdctl_url}" "${nerdctl_file}"
    download "${localpath_url}" "${localpath_file}"
    download "${kubernetes_url}" "${kubernetes_file}"
    download "${coredns_url}" "${coredns_file}.base"
    download "${metrics_url}" "${metrics_file}"
    download "${k9s_url}" "${k9s_file}"
    download "${calico_url}" "${calico_file}"
}

function download() {
    file_url="$1"
    file_name="$2"

    if [ -f "${download_path}/${file_name}" ]; then
        note "${download_path}/${file_name} exists"
        return 0
    fi

    note "download ${file_url}"
    if curl -L --progress-bar "${file_url}" -o "${download_path}/${file_name}"; then
        success "download ${file_name}"
    else
        error "download ${file_name} failed"
    fi
}

function sync_image() {
    src_image="$1"
    dst_image="$2"

    if [ -n "${registry_proxy}" ]; then
        src_image=${registry_proxy}/${src_image}
    fi

    if docker pull --platform linux/${arch_name} "${src_image}"; then
        docker tag "${src_image}" "${dst_image}"
        if ! docker push "${dst_image}"; then
            error "push ${dst_image} failed"
        fi
    else
        error "pull ${src_image} failed"
    fi
}

