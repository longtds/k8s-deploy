#!/bin/bash
# shellcheck disable=SC2087,SC2086,SC2206,SC2016,SC1091,SC2154

for f in lib/common.sh config.ini lib/remote.sh lib/plugin.sh lib/uninstall.sh; do
    if [ -f "$f" ]; then
        source "$f"
    else
        echo "file $f not found."
        exit 1
    fi
done

set +e
if [ ${#node_ip[@]} -ge 3 ]; then
    master_node=(${node_ip[0]} ${node_ip[1]} ${node_ip[2]})
else
    master_node=(${node_ip[0]})
fi

# 插件清单渲染需替换镜像占位符, 与 deploy.sh 保持一致
registry=${node_ip[0]}:5000

if [ $1 == "all" ]; then
    allnode_ip=(${node_ip[@]} ${addnode_ip[@]})
else
    allnode_ip=(${node_ip[@]})
fi

# 过滤不可达节点(如未部署的 addnode 节点), 避免卸载流程中断
online_ip=()
for ip in ${allnode_ip[@]}; do
    if ssh -i ${ssh_key} -p ${ssh_port} -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes ${ssh_user}@${ip} true 2>/dev/null; then
        online_ip+=(${ip})
    else
        echo "skip unreachable node: ${ip}"
    fi
done
allnode_ip=(${online_ip[@]})

export KUBECONFIG=${run_path}/admin.kubeconfig

# 先优雅卸载已安装的可选插件(如 prometheus 的 admission webhook/CRD), 避免通用强删挂起
plugins_remove_all

delete_resource
delete_service "${allnode_ip[@]}"
kill_process "${allnode_ip[@]}"
delete_config "${allnode_ip[@]}"
delete_bin "${allnode_ip[@]}"
kill_process "${allnode_ip[@]}"
umount_path "${allnode_ip[@]}"
delete_data "${allnode_ip[@]}"
delete_local
