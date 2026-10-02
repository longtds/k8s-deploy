# shellcheck shell=bash

function remote_exec() {
    local host=$1
    local cmd=$2
    if ! ssh -i ${ssh_key} -p ${ssh_port} -o ConnectTimeout=10 -o StrictHostKeyChecking=no ${ssh_user}@${host} "${cmd}" >/dev/null 2>&1; then
        error "Execute command failed on ${host}: ${cmd}"
    fi
}

# 软执行: 失败仅返回非零, 不中断脚本(用于卸载等容忍部分失败的场景)
function remote_exec_soft() {
    local host=$1
    local cmd=$2
    ssh -i ${ssh_key} -p ${ssh_port} -o ConnectTimeout=10 -o StrictHostKeyChecking=no ${ssh_user}@${host} "${cmd}" >/dev/null 2>&1
}

function remote_capture() {
    local host=$1
    local cmd=$2
    ssh -i ${ssh_key} -p ${ssh_port} -o ConnectTimeout=10 -o StrictHostKeyChecking=no ${ssh_user}@${host} "${cmd}" 2>/dev/null
}

function remote_cp() {
    local src=$1
    local dst=$2
    local mode=$3
    if ! scp ${mode} -i ${ssh_key} -P ${ssh_port} -o ConnectTimeout=10 -o StrictHostKeyChecking=no ${src} ${ssh_user}@${dst} >/dev/null 2>&1; then
        error "Copy ${src} to ${dst} failed"
    else
        success "Copy ${src} to ${dst}"
    fi
}

