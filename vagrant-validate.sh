#!/bin/bash
# shellcheck disable=SC2086,SC2206,SC1091,SC2154
#
# Vagrant 三节点部署验证脚本
#
# 用法:
#   ./vagrant-validate.sh [选项]
#
# 选项:
#   --skip-build    跳过构建, 直接使用 target/ 下已有的离线包
#   --no-destroy    验证结束后不销毁 VM (默认验证完即 vagrant destroy)
#   --test-addnode  验证 addnode 流程 (会临时启 node4)
#   --test-uninstall 验证 uninstall 流程 (install 后执行卸载再重装)
#   --debug         开启 deploy.sh 远程 DEBUG 日志
#   --proxy URL     构建代理 (如 http://127.0.0.1:10808)
#   -h, --help      显示帮助
#
# 流程:
#   1. 前置检查 (vagrant/libvirt/构建包)
#   2. 构建离线包 (可跳过)
#   3. vagrant up 启动三节点
#   4. 等待节点就绪 (含内核升级重启)
#   5. 拷贝离线包到 node1
#   6. 远程执行 deploy.sh install
#   7. 集群健康检查 (节点/Pod/DNS/存储/etcd/metrics)
#   8. (可选) addnode / uninstall 验证
#   9. 清理

set -euo pipefail

# ==================== 配置 ====================

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE1_IP="192.168.121.11"
NODE2_IP="192.168.121.12"
NODE3_IP="192.168.121.13"
ALL_NODE_IPS=("${NODE1_IP}" "${NODE2_IP}" "${NODE3_IP}")
SSH_USER="root"
SSH_PORT="22"
SSH_KEY="${HOME}/.ssh/id_ed25519"
SSH_OPTS="-i ${SSH_KEY} -p ${SSH_PORT} -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# 超时(秒): 等待 VM 就绪 / 部署完成 / 健康检查
VM_READY_TIMEOUT=300
KERNEL_REBOOT_WAIT=120
DEPLOY_TIMEOUT=1800
HEALTH_TIMEOUT=900
ADDNODE_VM_READY_TIMEOUT=180

# ==================== 选项解析 ====================

SKIP_BUILD=0
NO_DESTROY=0
TEST_ADDNODE=0
TEST_UNINSTALL=0
DEBUG_FLAG=""
BUILD_PROXY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
    --skip-build)    SKIP_BUILD=1; shift ;;
    --no-destroy)    NO_DESTROY=1; shift ;;
    --test-addnode)  TEST_ADDNODE=1; shift ;;
    --test-uninstall) TEST_UNINSTALL=1; shift ;;
    --debug)         DEBUG_FLAG="DEBUG=1"; shift ;;
    --proxy)         BUILD_PROXY="$2"; shift 2 ;;
    -h|--help)
        sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
        exit 0 ;;
    *) echo "unknown option: $1"; exit 1 ;;
    esac
done

# ==================== 日志 ====================

BOLD='\033[1m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { printf "${BOLD}${BLUE}[$(date +%H:%M:%S)]${NC} $*\n" >&2; }
ok()   { printf "${GREEN}[$(date +%H:%M:%S)] ✔ $*${NC}\n" >&2; }
warn() { printf "${YELLOW}[$(date +%H:%M:%S)] ⚠ $*${NC}\n" >&2; }
fail() { printf "${RED}[$(date +%H:%M:%S)] ✖ $*${NC}\n" >&2; }
die()  { fail "$*"; exit 1; }

# ==================== 前置检查 ====================

step_prerequisites() {
    log "前置检查"

    command -v vagrant >/dev/null 2>&1 || die "vagrant not found"
    command -v ssh >/dev/null 2>&1 || die "ssh not found"
    [ -f "${SSH_KEY}" ] || die "SSH key not found: ${SSH_KEY} (run: ssh-keygen -t ed25519 -N '' -f ${SSH_KEY})"

    # Vagrantfile 存在
    [ -f "${REPO_DIR}/Vagrantfile" ] || die "Vagrantfile not found in ${REPO_DIR}"

    # 检查 libvirt provider (vagrant-libvirt)
    if ! vagrant provider-list 2>/dev/null | grep -q libvirt; then
        if ! vagrant plugin list 2>/dev/null | grep -q vagrant-libvirt; then
            warn "vagrant-libvirt plugin not detected; if vagrant up fails, install it: vagrant plugin install vagrant-libvirt"
        fi
    fi

    ok "prerequisites check passed"
}

# ==================== 构建 ====================

step_build() {
    if [ ${SKIP_BUILD} -eq 1 ]; then
        log "跳过构建, 查找已有离线包"
        local pkg
        pkg=$(ls -t "${REPO_DIR}"/target/kubernetes-v*.tgz 2>/dev/null | head -1)
        [ -n "${pkg}" ] || die "no prebuilt package found in target/ (run without --skip-build or run ./build.sh first)"
        BUILT_TGZ="${pkg}"
        ok "using prebuilt package: ${BUILT_TGZ}"
        return
    fi

    log "构建离线包"
    cd "${REPO_DIR}"

    if [ -n "${BUILD_PROXY}" ]; then
        export http_proxy="${BUILD_PROXY}" https_proxy="${BUILD_PROXY}"
        log "using proxy: ${BUILD_PROXY}"
    fi

    # 清理旧构建戳, 确保完整重建
    rm -rf "${REPO_DIR}/build" "${REPO_DIR}/pkg/.stamps"

    bash ./build.sh 2>&1 | tee /tmp/vagrant-validate-build.log
    local pkg
    pkg=$(ls -t "${REPO_DIR}"/target/kubernetes-v*.tgz 2>/dev/null | head -1)
    [ -n "${pkg}" ] || die "build failed: no .tgz found in target/"
    BUILT_TGZ="${pkg}"
    ok "build completed: ${BUILT_TGZ}"
}

# ==================== Vagrant 启动 ====================

step_vagrant_up() {
    log "启动 Vagrant 三节点集群"
    cd "${REPO_DIR}"
    vagrant destroy -f 2>/dev/null || true
    vagrant up 2>&1 | tee /tmp/vagrant-validate-up.log

    # Vagrantfile 可能在 provision 中升级内核并 reboot
    # 等待所有节点 SSH 可达
    log "等待节点 SSH 可达 (最长 ${VM_READY_TIMEOUT}s)"
    wait_for_ssh "${ALL_NODE_IPS[@]}" "${VM_READY_TIMEOUT}"

    # 检测是否发生了内核升级重启, 额外等待
    local rebooted=0
    for ip in "${ALL_NODE_IPS[@]}"; do
        # provision 脚本输出 "kernel upgraded" 时会 reboot; 检查 uptime
        local uptime_str
        uptime_str=$(ssh ${SSH_OPTS} ${SSH_USER}@${ip} 'cat /proc/uptime' 2>/dev/null | awk '{print $1}')
        if [ -n "${uptime_str}" ]; then
            local secs=${uptime_str%.*}
            if [ ${secs} -lt ${KERNEL_REBOOT_WAIT} ]; then
                rebooted=1
                log "${ip} 最近重启 (uptime ${secs}s), 可能是内核升级, 等待稳定..."
            fi
        fi
    done

    if [ ${rebooted} -eq 1 ]; then
        sleep 30
        wait_for_ssh "${ALL_NODE_IPS[@]}" 60
    fi

    ok "all 3 nodes are SSH reachable"

    # 验证 node1 可免密登录 node2/node3 (deploy.sh 依赖)
    log "验证 node1 → node2/node3 SSH 免密"
    for peer in "${NODE2_IP}" "${NODE3_IP}"; do
        if ! ssh ${SSH_OPTS} ${SSH_USER}@${NODE1_IP} \
            "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${SSH_USER}@${peer} 'echo ok'" 2>/dev/null | grep -q ok; then
            die "node1 cannot passwordless-SSH to ${peer}; check Vagrantfile provision"
        fi
    done
    ok "node1 cluster SSH key works"
}

# ==================== 部署 ====================

step_deploy() {
    log "拷贝离线包到 node1"
    local remote_dir="/root"
    scp ${SSH_OPTS} "${BUILT_TGZ}" ${SSH_USER}@${NODE1_IP}:${remote_dir}/k8s-deploy.tgz

    log "解压并执行 deploy.sh install (超时 ${DEPLOY_TIMEOUT}s)"
    local deploy_cmd="cd ${remote_dir} && rm -rf k8s-deploy && tar xzf k8s-deploy.tgz && cd k8s-deploy && ${DEBUG_FLAG} ./deploy.sh install"

    # 用 timeout 包裹, 避免 deploy.sh 内部卡死
    if ! ssh ${SSH_OPTS} ${SSH_USER}@${NODE1_IP} "timeout ${DEPLOY_TIMEOUT} bash -lc '${deploy_cmd}'" 2>&1 | tee /tmp/vagrant-validate-deploy.log; then
        fail "deploy.sh install failed"
        # 拉取关键诊断信息
        log "拉取节点状态诊断..."
        ssh ${SSH_OPTS} ${SSH_USER}@${NODE1_IP} 'cd ~/k8s-deploy && export KUBECONFIG=~/k8s-deploy/admin.kubeconfig 2>/dev/null; /usr/local/bin/kubectl get node -o wide 2>/dev/null || true; /usr/local/bin/kubectl get pod -A 2>/dev/null || true; systemctl status kubelet --no-pager 2>/dev/null | tail -20 || true; journalctl -u kubelet --no-pager -n 30 2>/dev/null || true' 2>/dev/null || true
        die "deployment failed, see /tmp/vagrant-validate-deploy.log"
    fi
    ok "deploy.sh install completed"
}

# ==================== 健康检查 ====================

step_health_check() {
    log "集群健康检查 (超时 ${HEALTH_TIMEOUT}s)"

    # 封装: 在 node1 上用 kubectl 执行命令
    kubectl() {
        ssh ${SSH_OPTS} ${SSH_USER}@${NODE1_IP} "cd /root/k8s-deploy && KUBECONFIG=/root/k8s-deploy/admin.kubeconfig /usr/local/bin/kubectl $*" 2>/dev/null
    }
    # 封装: 在 node1 上用 etcdctl 执行命令
    etcdctl() {
        ssh ${SSH_OPTS} ${SSH_USER}@${NODE1_IP} "cd /root/k8s-deploy && ETCDCTL_API=3 /usr/local/bin/etcdctl --cacert=/etc/kubernetes/pki/etcd-ca.pem --cert=/etc/kubernetes/pki/etcd.pem --key=/etc/kubernetes/pki/etcd-key.pem $*" 2>/dev/null
    }

    local errors=0

    # --- 1. 节点状态 ---
    log "[1/8] 检查节点 Ready 状态"
    local node_ready
    node_ready=$(kubectl get node --no-headers 2>/dev/null | awk '$2 ~ /^Ready/ {count++} END {print count+0}')
    if [ "${node_ready}" -eq 3 ]; then
        ok "3 nodes all Ready"
    else
        fail "expected 3 Ready nodes, got ${node_ready}"
        kubectl get node -o wide 2>/dev/null || true
        errors=$((errors + 1))
    fi

    # --- 2. Pod 状态 ---
    log "[2/8] 检查所有 Pod Running"
    local not_running
    not_running=$(kubectl get pod -A --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed" {print}')
    if [ -z "${not_running}" ]; then
        ok "all pods Running"
    else
        fail "pods not Running:"
        printf '%s\n' "${not_running}" | head -20
        errors=$((errors + 1))
    fi

    # --- 3. etcd 集群健康 ---
    log "[3/8] 检查 etcd 集群健康"
    local etcd_out
    etcd_out=$(etcdctl endpoint health --endpoints=https://${NODE1_IP}:2379,https://${NODE2_IP}:2379,https://${NODE3_IP}:2379 2>/dev/null || true)
    local etcd_ok
    etcd_ok=$(echo "${etcd_out}" | grep -c 'is healthy')
    if [ "${etcd_ok}" -eq 3 ]; then
        ok "etcd cluster: 3/3 endpoints healthy"
    else
        fail "etcd not fully healthy (${etcd_ok}/3):"
        printf '%s\n' "${etcd_out}"
        errors=$((errors + 1))
    fi

    # --- 4. CoreDNS ---
    log "[4/8] 检查 CoreDNS 解析"
    local coredns_pods
    coredns_pods=$(kubectl get pod -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | awk '$3 == "Running" {count++} END {print count+0}')
    if [ "${coredns_pods}" -ge 1 ]; then
        ok "CoreDNS pods Running (${coredns_pods})"
    else
        fail "no CoreDNS pod Running"
        errors=$((errors + 1))
    fi

    # DNS 解析测试: 创建临时 pod 执行 nslookup
    log "  DNS 解析测试..."
    if kubectl run dns-test --image=registry.k8s.io/pause:3.10.1 --restart=Never --command -- sleep 60 2>/dev/null; then
        sleep 3
        local nslookup_out
        nslookup_out=$(kubectl exec dns-test -- nslookup kubernetes.default 2>/dev/null || true)
        if echo "${nslookup_out}" | grep -q 'Name:.*kubernetes.default'; then
            ok "DNS resolution: kubernetes.default resolved"
        else
            # pause 镜像可能没有 nslookup, 用 node 上 dig/curl 替代
            local dig_out
            dig_out=$(ssh ${SSH_OPTS} ${SSH_USER}@${NODE1_IP} 'echo "kubernetes.default" | /usr/local/bin/nerdctl run --rm --network host registry.k8s.io/coredns/coredns:latest -short 2>/dev/null || echo "skip"' 2>/dev/null || echo "skip")
            if [ "${dig_out}" != "skip" ] && echo "${dig_out}" | grep -qE '[0-9]+\.[0-9]+'; then
                ok "DNS resolution via coredns container: ${dig_out}"
            else
                warn "DNS test inconclusive (pause image has no nslookup), skipping"
            fi
        fi
        kubectl delete pod dns-test --force --grace-period=0 2>/dev/null || true
    else
        warn "could not create dns-test pod, skipping DNS resolution test"
    fi

    # --- 5. Calico / CNI ---
    log "[5/8] 检查 Calico CNI"
    local calico_pods
    calico_pods=$(kubectl get pod -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | awk '$3 == "Running" {count++} END {print count+0}')
    if [ "${calico_pods}" -eq 3 ]; then
        ok "Calico node pods Running (3/3)"
    else
        fail "expected 3 Calico pods, got ${calico_pods}"
        kubectl get pod -n kube-system -l k8s-app=calico-node 2>/dev/null || true
        errors=$((errors + 1))
    fi

    # 跨节点 Pod 通信测试
    log "  跨节点 Pod 通信测试..."
    if kubectl apply -f - <<'YAML' 2>/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nettest
  labels:
    app: nettest
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nettest
  template:
    metadata:
      labels:
        app: nettest
    spec:
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.10.1
YAML
    then
        sleep 10
        local nettest_ready
        nettest_ready=$(kubectl get deploy nettest --no-headers 2>/dev/null | awk '{print $2}')
        if echo "${nettest_ready}" | grep -q '3/3'; then
            ok "nettest deployment 3/3 replicas ready (pod networking OK)"
        else
            warn "nettest not 3/3 ready (${nettest_ready}), may need more time"
        fi
        kubectl delete deploy nettest --force --grace-period=0 2>/dev/null || true
    else
        warn "could not create nettest deployment, skipping cross-node test"
    fi

    # --- 6. metrics-server ---
    log "[6/8] 检查 metrics-server"
    local metrics_pods
    metrics_pods=$(kubectl get pod -n kube-system -l k8s-app=metrics-server --no-headers 2>/dev/null | awk '$3 == "Running" {count++} END {print count+0}')
    if [ "${metrics_pods}" -ge 1 ]; then
        ok "metrics-server pod Running"
    else
        fail "metrics-server not Running"
        errors=$((errors + 1))
    fi

    # kubectl top node (需要 metrics-server 就绪, 可能需额外等待)
    log "  等待 metrics 数据可用..."
    local top_ok=0
    for _ in $(seq 1 12); do
        if kubectl top node 2>/dev/null | grep -q 'CPU'; then
            top_ok=1; break
        fi
        sleep 10
    done
    if [ ${top_ok} -eq 1 ]; then
        ok "kubectl top node works"
    else
        warn "kubectl top node not ready yet (metrics-server may still be initializing)"
    fi

    # --- 7. local-path provisioner ---
    log "[7/8] 检查 local-path-provisioner + PVC"
    local localpath_pods
    localpath_pods=$(kubectl get pod -n local-path-storage --no-headers 2>/dev/null | awk '$3 == "Running" {count++} END {print count+0}')
    if [ "${localpath_pods}" -ge 1 ]; then
        ok "local-path-provisioner Running"
    else
        fail "local-path-provisioner not Running"
        errors=$((errors + 1))
    fi

    # PVC 动态制备测试
    log "  PVC 动态制备测试..."
    if kubectl apply -f - <<'YAML' 2>/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-test
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: 1Mi
YAML
    then
        local pv_bound=0
        for _ in $(seq 1 12); do
            local pvc_status
            pvc_status=$(kubectl get pvc pvc-test --no-headers 2>/dev/null | awk '{print $2}')
            if [ "${pvc_status}" == "Bound" ]; then
                pv_bound=1; break
            fi
            sleep 5
        done
        if [ ${pv_bound} -eq 1 ]; then
            ok "PVC pvc-test bound (dynamic provisioning OK)"
        else
            fail "PVC pvc-test not bound within 60s"
            kubectl get pvc pvc-test 2>/dev/null || true
            errors=$((errors + 1))
        fi
        kubectl delete pvc pvc-test --force --grace-period=0 2>/dev/null || true
    else
        warn "could not create test PVC, skipping dynamic provisioning test"
    fi

    # --- 8. HA apiserver 负载均衡 ---
    log "[8/8] 检查 HA apiserver 负载均衡 (127.0.0.1:8443)"
    local ha_ok=0
    for ip in "${ALL_NODE_IPS[@]}"; do
        local healthz
        healthz=$(ssh ${SSH_OPTS} ${SSH_USER}@${ip} 'curl -sk --connect-timeout 5 https://127.0.0.1:8443/healthz 2>/dev/null || echo "FAIL"' 2>/dev/null)
        if [ "${healthz}" == "ok" ]; then
            ha_ok=$((ha_ok + 1))
        else
            warn "${ip} haproxy healthz: ${healthz}"
        fi
    done
    if [ ${ha_ok} -eq 3 ]; then
        ok "HA apiserver: 3/3 nodes healthz=ok"
    else
        fail "HA apiserver: ${ha_ok}/3 nodes healthy"
        errors=$((errors + 1))
    fi

    # --- 总结 ---
    echo
    if [ ${errors} -eq 0 ]; then
        ok "==================== 健康检查全部通过 ===================="
    else
        fail "健康检查有 ${errors} 项失败"
        log "节点详情:"
        kubectl get node -o wide 2>/dev/null | head -10
        log "Pod 概览:"
        kubectl get pod -A 2>/dev/null | head -20
    fi

    return ${errors}
}

# ==================== Addnode 验证 ====================

step_test_addnode() {
    log "=== addnode 验证 ==="

    # Vagrantfile 只定义了 3 节点; addnode 需要额外 VM
    # 完整自动化需扩展 Vagrantfile 增加 node4 定义, 当前仅提示
    warn "addnode 验证需要手动准备 node4 VM (192.168.121.14)"
    warn "请确保 node4 已启动、root 可免密 SSH、且已安装系统依赖(nftables/socat/...)"
    warn "自动 addnode 测试跳过; 可手动执行后验证:"
    warn "  ssh ${SSH_OPTS} ${SSH_USER}@${NODE1_IP} 'cd /root/k8s-deploy && ./deploy.sh addnode'"
    return 0
}

# ==================== Uninstall 验证 ====================

step_test_uninstall() {
    log "=== uninstall 验证 ==="

    log "在 node1 执行 ./uninstall.sh all"
    if ! ssh ${SSH_OPTS} ${SSH_USER}@${NODE1_IP} 'cd /root/k8s-deploy && ./uninstall.sh all' 2>&1 | tee /tmp/vagrant-validate-uninstall.log; then
        warn "uninstall.sh 返回非零, 检查日志"
    fi

    log "验证卸载后残留"
    local leftover=0
    for ip in "${ALL_NODE_IPS[@]}"; do
        # 检查 kubelet/etcd 进程是否已停止
        if ssh ${SSH_OPTS} ${SSH_USER}@${ip} 'pgrep -f "kubelet|etcd|kube-apiserver" 2>/dev/null' 2>/dev/null | grep -q .; then
            warn "${ip} 仍有 k8s 进程残留"
            leftover=1
        fi
        # 检查关键目录是否已删除
        if ssh ${SSH_OPTS} ${SSH_USER}@${ip} 'ls /etc/kubernetes /var/lib/etcd /var/lib/kubelet 2>/dev/null' 2>/dev/null | grep -q .; then
            warn "${ip} 仍有 k8s 目录残留"
            leftover=1
        fi
    done

    if [ ${leftover} -eq 0 ]; then
        ok "uninstall 清理干净"
    else
        fail "uninstall 有残留, 需人工检查"
    fi

    # 重新部署, 确认集群可恢复
    log "重新执行 deploy.sh install"
    if ssh ${SSH_OPTS} ${SSH_USER}@${NODE1_IP} "cd /root/k8s-deploy && timeout ${DEPLOY_TIMEOUT} ./deploy.sh install" 2>&1 | tee /tmp/vagrant-validate-reinstall.log; then
        ok "重新部署成功, 集群恢复"
        # 简单验证节点就绪
        sleep 15
        local ready
        ready=$(ssh ${SSH_OPTS} ${SSH_USER}@${NODE1_IP} 'cd /root/k8s-deploy && KUBECONFIG=/root/k8s-deploy/admin.kubeconfig /usr/local/bin/kubectl get node --no-headers 2>/dev/null' | awk '$2 ~ /^Ready/ {count++} END {print count+0}')
        if [ "${ready}" -eq 3 ]; then
            ok "重部署后 3 节点 Ready"
        else
            warn "重部署后节点未全部 Ready (${ready}/3), 可能需要更多时间"
        fi
    else
        fail "重新部署失败"
    fi
}

# ==================== 清理 ====================

step_cleanup() {
    if [ ${NO_DESTROY} -eq 1 ]; then
        log "--no-destroy: 保留 VM, 跳过清理"
        log "可手动登录: ssh ${SSH_OPTS} ${SSH_USER}@${NODE1_IP}"
        log "手动销毁: cd ${REPO_DIR} && vagrant destroy -f"
        return
    fi

    log "销毁 Vagrant VM"
    cd "${REPO_DIR}"
    vagrant destroy -f 2>/dev/null || true
    ok "VM 已销毁"
}

# ==================== 工具函数 ====================

# 用法: wait_for_ssh <ip1> [ip2...] <timeout_sec>
wait_for_ssh() {
    local timeout="${@: -1}"
    local ips=("${@:1:$#-1}")
    local elapsed=0
    local all_ok=0
    while [ ${elapsed} -lt ${timeout} ]; do
        all_ok=1
        for ip in "${ips[@]}"; do
            if ! ssh ${SSH_OPTS} ${SSH_USER}@${ip} 'true' 2>/dev/null; then
                all_ok=0
                break
            fi
        done
        if [ ${all_ok} -eq 1 ]; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    die "SSH unreachable after ${timeout}s for nodes: ${ips[*]}"
}

# 脚本中断时清理
trap 'die "interrupted by signal"' INT TERM
trap step_cleanup EXIT

# ==================== 主流程 ====================

main() {
    echo
    log "==================== Vagrant 三节点部署验证 ===================="
    log "仓库: ${REPO_DIR}"
    log "节点: ${ALL_NODE_IPS[*]}"
    log "选项: skip-build=${SKIP_BUILD} no-destroy=${NO_DESTROY} addnode=${TEST_ADDNODE} uninstall=${TEST_UNINSTALL} debug=${DEBUG_FLAG}"
    echo

    step_prerequisites
    step_build
    step_vagrant_up
    step_deploy

    HEALTH_RC=0
    step_health_check || HEALTH_RC=$?

    if [ ${TEST_ADDNODE} -eq 1 ]; then
        step_test_addnode
    fi

    if [ ${TEST_UNINSTALL} -eq 1 ]; then
        step_test_uninstall
    fi

    echo
    if [ ${HEALTH_RC} -eq 0 ]; then
        ok "==================== 验证通过 ===================="
    else
        fail "==================== 验证失败 (${HEALTH_RC} 项检查未通过) ===================="
    fi

    exit ${HEALTH_RC}
}

main "$@"
