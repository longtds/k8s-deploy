#!/bin/bash
# shellcheck disable=all

for f in lib/common.sh config.ini lib/build-common.sh lib/build-package.sh lib/build-image.sh; do
    if [ -f "$f" ]; then
        source "$f"
    else
        echo "file $f not found."
        exit 1
    fi
done

# 支持构建的架构及默认架构
support_arch=(x86_64 aarch64)
default_arch=${arch}
root_path=${PWD}

build_arch=()
if [ $# -eq 0 ]; then
    build_arch=(${default_arch})
else
    for i in $@; do
        case ${i} in
        all)
            build_arch=(${support_arch[@]})
            ;;
        x86_64 | aarch64)
            build_arch+=(${i})
            ;;
        *)
            usage
            ;;
        esac
    done
fi

host_arch=$(host_arch_name)

# 容器运行时能力检测 (docker / nerdctl)
detect_container_runtime

# 代理透传: 构建机若已设置 http_proxy/https_proxy, docker/nerdctl 会自动使用
# 如需指定代理, 执行 build.sh 前设置:
#   export http_proxy=http://127.0.0.1:10808 https_proxy=http://127.0.0.1:10808
if [ -n "${http_proxy:-}" ] || [ -n "${https_proxy:-}" ]; then
    note "using proxy: http_proxy=${http_proxy:-} https_proxy=${https_proxy:-}"
fi

for i in ${build_arch[@]}; do
    h1 "build ${i}"
    load_config ${i}
    download_file
    make_binary
    make_yaml
    make_tgz
    make_registry
    make_haproxy
    make_image
    make_config
    make_target
done
