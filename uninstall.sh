#!/bin/bash
# shellcheck disable=SC2087,SC2086,SC2206,SC2016,SC1091,SC2154

for f in lib/common.sh config.ini lib/remote.sh lib/uninstall.sh; do
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

if [ $1 == "all" ]; then
    allnode_ip=(${node_ip[@]} ${addnode_ip[@]})
else
    allnode_ip=(${node_ip[@]})
fi

export KUBECONFIG=${run_path}/admin.kubeconfig

delete_resource
delete_service "${allnode_ip[@]}"
kill_process "${allnode_ip[@]}"
delete_config "${allnode_ip[@]}"
delete_bin "${allnode_ip[@]}"
kill_process "${allnode_ip[@]}"
umount_path "${allnode_ip[@]}"
delete_data "${allnode_ip[@]}"
delete_local
