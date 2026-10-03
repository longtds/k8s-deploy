# shellcheck shell=bash

function sync_pkg() {
    args=($@)
    num=$#

    command1="tar xf /tmp/${nerdctl_file} -C /usr/local/"
    command2="mkdir -p ${bin_path} && cp -f /tmp/k8s-bin/* ${bin_path}/ && rm -rf /tmp/k8s-bin"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "rm -rf /tmp/k8s-bin" &&
            remote_cp "${pkg_path}/bin" "${args[${i}]}:/tmp/k8s-bin" -r &&
            remote_exec ${args[${i}]} "${command2}"; then
            success "${args[${i}]} ${pkg_path}/bin copied"
        fi

        if remote_cp "${pkg_path}/image/${haproxy_file}" "${args[${i}]}:/tmp/${haproxy_file}"; then
            success "${args[${i}]} ${haproxy_file} copied"
        fi

        if remote_cp "${pkg_path}/tgz/${nerdctl_file}" "${args[${i}]}:/tmp/${nerdctl_file}"; then
            remote_exec ${args[${i}]} "${command1}"
            success "${args[${i}]} ${nerdctl_file} copied"
        fi

        # 系统依赖离线包：rhel/deb 各一份, 部署时按目标系统类型选用
        if remote_exec ${args[${i}]} "rm -rf /tmp/k8s-deps" &&
            remote_cp "${pkg_path}/deps" "${args[${i}]}:/tmp/k8s-deps" -r; then
            success "${args[${i}]} ${pkg_path}/deps copied"
        fi
    done

    command3="mkdir -p ${registry_data_path} && tar xf /tmp/${image_file} -C ${registry_data_path} --strip-components=1"

    if remote_cp "${pkg_path}/image/${image_file}" "${master_node[0]}:/tmp/${image_file}" &&
        remote_exec ${master_node[0]} "${command3}"; then
        success "${master_node[0]} ${image_file} copied"
    fi

    if remote_cp "${pkg_path}/image/${registry_file}" "${master_node[0]}:/tmp/${registry_file}"; then
        success "${master_node[0]} ${registry_file} copied"
    fi
}

