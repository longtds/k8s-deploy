# shellcheck shell=bash

# 远程操作统一封装:
#   - 所有远程输出落盘到 ${run_path}/logs/<host>.log, 便于排障
#   - 失败时在控制台回显末尾输出, 不再只报命令不报原因
#   - DEBUG=1 时实时回显全部远程输出
function _ssh_logfile() {
    local host=$1
    echo "${run_path:-${PWD}}/logs/${host}.log"
}

function _record() {
    local host=$1 title=$2 out=$3 rc=$4
    local logfile
    logfile=$(_ssh_logfile "${host}")
    mkdir -p "$(dirname "${logfile}")"
    {
        printf '\n===== %s | %s | rc=%s =====\n' "$(TZ=UTC-8 date +%Y-%m-%d" "%H:%M:%S)" "${title}" "${rc}"
        printf '%s\n' "${out}"
    } >>"${logfile}"

    if [ "${DEBUG:-0}" == "1" ] && [ -n "${out}" ]; then
        printf '%s\n' "${out}" | sed "s/^/[${host}] /"
    fi

    if [ "${rc}" != "0" ]; then
        warn "last output from ${host} (full log: ${logfile})"
        printf '%s\n' "${out}" | tail -n 20 | sed "s/^/[${host}] /" >&2
    fi
}

function remote_exec() {
    local host=$1
    local cmd=$2
    local out rc
    if out=$(ssh -i ${ssh_key} -p ${ssh_port} -o ConnectTimeout=10 -o StrictHostKeyChecking=no ${ssh_user}@${host} "${cmd}" 2>&1); then
        rc=0
    else
        rc=$?
    fi
    _record "${host}" "${cmd}" "${out}" "${rc}"
    if [ ${rc} -ne 0 ]; then
        error "Execute command failed on ${host}: ${cmd}"
    fi
}

# 软执行: 失败仅返回非零, 不中断脚本(用于卸载等容忍部分失败的场景)
function remote_exec_soft() {
    local host=$1
    local cmd=$2
    local out rc
    if out=$(ssh -i ${ssh_key} -p ${ssh_port} -o ConnectTimeout=10 -o StrictHostKeyChecking=no ${ssh_user}@${host} "${cmd}" 2>&1); then
        rc=0
    else
        rc=$?
    fi
    _record "${host}" "${cmd}" "${out}" "${rc}"
    return ${rc}
}

function remote_capture() {
    local host=$1
    local cmd=$2
    local logfile
    logfile=$(_ssh_logfile "${host}")
    mkdir -p "$(dirname "${logfile}")"
    # 子 shell 开 pipefail: ssh/远程命令的失败必须透传给调用方(如 etcd 就绪轮询),
    # 不能被管道末端 tee 的成功掩盖
    (
        set -o pipefail
        {
            printf '\n===== %s | CAPTURE: %s =====\n' "$(TZ=UTC-8 date +%Y-%m-%d" "%H:%M:%S)" "${cmd}"
            ssh -i ${ssh_key} -p ${ssh_port} -o ConnectTimeout=10 -o StrictHostKeyChecking=no ${ssh_user}@${host} "${cmd}" 2>/dev/null
        } | tee -a "${logfile}"
    )
}

function remote_cp() {
    local src=$1
    local dst=$2
    local mode=$3
    local out rc
    if out=$(scp ${mode} -i ${ssh_key} -P ${ssh_port} -o ConnectTimeout=10 -o StrictHostKeyChecking=no ${src} ${dst} 2>&1); then
        rc=0
    else
        rc=$?
    fi
    _record "${dst%%:*}" "scp ${src} -> ${dst}" "${out}" "${rc}"
    if [ ${rc} -ne 0 ]; then
        error "Copy ${src} to ${dst} failed"
    else
        success "Copy ${src} to ${dst}"
    fi
}

# 从节点拉取文件到部署机(失败即中止, 与 remote_cp 同等级别)
function remote_pull() {
    local host=$1
    local src=$2
    local dst=$3
    local out rc
    if out=$(scp -i ${ssh_key} -P ${ssh_port} -o ConnectTimeout=10 -o StrictHostKeyChecking=no ${ssh_user}@${host}:${src} ${dst} 2>&1); then
        rc=0
    else
        rc=$?
    fi
    _record "${host}" "scp pull ${src} -> ${dst}" "${out}" "${rc}"
    if [ ${rc} -ne 0 ]; then
        error "Pull ${src} from ${host} to ${dst} failed"
    fi
}

# 将本地 src_dir 下的多个指定文件通过 tar 管道原样推送到节点 dst_dir
# 用法: remote_send_files <host> <src_dir> <dst_dir> <file1> [file2 ...]
function remote_send_files() {
    local host=$1
    local src_dir=$2
    local dst_dir=$3
    shift 3
    local out rc
    # pipefail: tar(如本地证书缺失)失败不能被 ssh 成功掩盖
    if out=$(set -o pipefail; tar czf - -C "${src_dir}" "$@" 2>/dev/null |
        ssh -i ${ssh_key} -p ${ssh_port} -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
            ${ssh_user}@${host} "mkdir -p '${dst_dir}' && tar xzf - -C '${dst_dir}'" 2>&1); then
        rc=0
    else
        rc=$?
    fi
    _record "${host}" "send files [ $* ] -> ${dst_dir}" "${out}" "${rc}"
    if [ ${rc} -ne 0 ]; then
        error "send files to ${host}:${dst_dir} failed"
    fi
}
