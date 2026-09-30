# shellcheck shell=bash

function remote_exec() {
    local host=$1
    local cmd=$2
    if ! ssh -i ${ssh_key} -p ${ssh_port} ${ssh_user}@${host} "${cmd}" >/dev/null 2>&1; then
        error "Execute command failed on ${host}: ${cmd}"
    fi
}

function remote_capture() {
    local host=$1
    local cmd=$2
    ssh -i ${ssh_key} -p ${ssh_port} ${ssh_user}@${host} "${cmd}" 2>/dev/null
}

function remote_cp() {
    local src=$1
    local dst=$2
    local mode=$3
    if ! scp ${mode} -i ${ssh_key} -P ${ssh_port} ${src} ${ssh_user}@${dst} >/dev/null 2>&1; then
        error "Copy ${src} to ${dst} failed"
    else
        success "Copy ${src} to ${dst}"
    fi
}

