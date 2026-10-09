# -*- mode: ruby -*-
# vi: set ft=ruby :

# 测试矩阵参数
BOX = "cloud-image/ubuntu-24.04"
# BOX = "cloud-image/ubuntu-22.04"
# BOX = "cloud-image/rocky-9"
# BOX = "generic/rocky9"
# BOX = "cloud-image/rocky-10"
# BOX = "cloud-image/debian-13"

CPUS = 4
MEM_MB = 4096
DISK_GB = 100

# 3-node cluster: consecutive IPs
NODES = [
  { name: "node1", ip: "192.168.121.11" },
  { name: "node2", ip: "192.168.121.12" },
  { name: "node3", ip: "192.168.121.13" },
]
NODE_IPS = NODES.map { |n| n[:ip] }.join(" ")

# 部署机公钥: deploy.sh 以 root + 私钥 SSH 各节点
root_pubkey = File.read(File.expand_path("~/.ssh/id_ed25519.pub")).strip

# 集群内部 SSH 密钥: node1 作为 deploy.sh 执行节点需要免密登录所有节点(含自身)。
# 密钥在宿主机生成一次并缓存到 .vagrant/, 公钥写入所有节点 authorized_keys,
# 私钥仅写入 node1, 避免跨节点分发时序问题。
cluster_key = File.expand_path(".vagrant/cluster_ed25519")
unless File.exist?(cluster_key)
  system("ssh-keygen -t ed25519 -N '' -f #{cluster_key} -q")
end
cluster_pub = File.read("#{cluster_key}.pub").strip
cluster_priv = File.read(cluster_key)

Vagrant.configure("2") do |config|
  config.vm.box = BOX

  # Configure root password and allow SSH root login (password + pubkey).
  config.vm.provision "root-access", type: "shell", inline: <<-SHELL
    set -euo pipefail

    # 1. Set the root password
    echo "root:vagrant@2026" | chpasswd

    # 2. Allow root password login via SSH.
    printf 'PermitRootLogin yes\\nPasswordAuthentication yes\\n' \
      > /etc/ssh/sshd_config.d/00-root-login.conf

    # 3. Install the deployer's public key for root (key auth used by deploy.sh)
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
    grep -qF '#{root_pubkey}' /root/.ssh/authorized_keys || \
      echo '#{root_pubkey}' >> /root/.ssh/authorized_keys
    # 4. 集群公钥: node1 持对应私钥, 可免密登录所有节点
    grep -qF '#{cluster_pub}' /root/.ssh/authorized_keys || \
      echo '#{cluster_pub}' >> /root/.ssh/authorized_keys

    # 5. Validate the configuration before reloading sshd
    sshd -t
    # rhel系服务名为 sshd, debian系为 ssh
    systemctl reload sshd 2>/dev/null || systemctl reload ssh
    echo "root access configured"
  SHELL

  # node1 写入集群私钥并配置 SSH 免交互; 其他节点直接跳过
  config.vm.provision "setup-node1-key", type: "shell", inline: <<-SHELL
    set -euo pipefail
    [ "$(hostname)" = "node1" ] || exit 0

    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    cat > /root/.ssh/id_ed25519 <<'CLUSTERKEY'
#{cluster_priv}
CLUSTERKEY
    chmod 600 /root/.ssh/id_ed25519
    ssh-keygen -y -f /root/.ssh/id_ed25519 > /root/.ssh/id_ed25519.pub
    chmod 644 /root/.ssh/id_ed25519.pub

    # 测试环境: 对集群节点关闭 host key 校验, 省去 ssh-keyscan 时序依赖
    cat > /root/.ssh/config <<EOF
Host #{NODE_IPS}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    User root
EOF
    chmod 600 /root/.ssh/config
    echo "node1 ssh key configured"
  SHELL

  # Install prerequisites listed in README.md
  config.vm.provision "install-deps", type: "shell", inline: <<-SHELL
    set -euo pipefail
    NODE_IPS="#{NODE_IPS}"

    if command -v dnf &>/dev/null; then
      # rhel系 (rocky/anolis/openeuler/uos/kylin)
      # 注意: Rocky 10 cloud box 内核缺少 ip_set/xt_conntrack 模块且仓库无匹配版本,
      # 必须允许内核升级并在升级后重启, 否则 Calico/kube-proxy 无法运行
      dnf install -y nftables iptables-nft socat ipset conntrack-tools iproute chrony kernel-modules-extra
    elif command -v apt-get &>/dev/null; then
      # debian系 (ubuntu/debian)
      # 关闭 deb-src 源码索引与 Translation 下载: apt 3.x(Debian 13)在无 swap 的
      # 小内存 VM 上处理超大索引会 OOM(apt-get update 被 kill); sed 对非 deb822
      # 格式源(旧版 sources.list)无匹配, 不影响 Ubuntu
      sed -i 's/^Types: deb deb-src/Types: deb/' /etc/apt/sources.list.d/*.sources 2>/dev/null || true
      # Debian 13 deb822 默认经 mirror+file 解析到 deb.debian.org, 国内环境极慢(几 KB/s),
      # 替换为阿里云镜像; 仅匹配 .sources(Deb822) 格式, 旧版 Ubuntu 的 sources.list 不受影响
      if grep -rql 'mirror+file:///etc/apt/mirrors/debian' /etc/apt/sources.list.d/*.sources 2>/dev/null; then
        sed -i 's|mirror+file:///etc/apt/mirrors/debian.list|https://mirrors.aliyun.com/debian|; s|mirror+file:///etc/apt/mirrors/debian-security.list|https://mirrors.aliyun.com/debian-security|' /etc/apt/sources.list.d/*.sources
      fi
      apt-get update -o Acquire::Languages=none
      apt-get install -y nftables iptables socat ipset conntrack iproute2 chrony
    else
      echo "ERROR: unsupported OS, neither dnf nor apt-get found" >&2
      exit 1
    fi

    # Vagrant libvirt 管理网卡(DHCP)与 private_network(静态)可能同网段,
    # etcd peer 流量若经 DHCP 网卡发出, 源 IP 不在证书 SAN 内会被 TLS 拒绝。
    # 为所有其他集群节点添加 /32 主机路由, 强制 peer 流量走静态网卡(SELinux
    # Enforcing 下 nmcli modify 连接文件可能被拒, 故用 ip route + systemd 持久化)。
    local_ip=""
    local_dev=""
    for ip in ${NODE_IPS}; do
      # grep 无匹配时返回非零, 加 || true 避免 set -e 中断
      dev=$(ip -o addr show 2>/dev/null | grep "inet ${ip}/" | awk '{print $2; exit}' || true)
      if [ -n "$dev" ]; then
        local_ip="$ip"
        local_dev="$dev"
        break
      fi
    done
    if [ -n "$local_ip" ] && [ -n "$local_dev" ]; then
      routes_cmd=""
      for peer in ${NODE_IPS}; do
        [ "$peer" = "$local_ip" ] && continue
        routes_cmd="${routes_cmd}ip route add ${peer}/32 dev ${local_dev} src ${local_ip} 2>/dev/null; "
      done
      cat > /etc/systemd/system/cluster-routes.service <<EOF
[Unit]
Description=Static /32 routes for cluster peer traffic
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '${routes_cmd}'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable --now cluster-routes.service
    fi

    echo "prerequisites installed"

    # dnf/apt 可能升级内核, 若运行内核与已安装最新内核不一致则重启,
    # 否则运行内核的 xt_conntrack/ip_set 等模块文件缺失, kube-proxy/Calico 同步失败。
    # Rocky/Anolis 云镜像内核包名为 kernel-core(非 kernel)。
    if command -v rpm &>/dev/null; then
      RUNNING=$(uname -r)
      LATEST=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V | tail -1)
      if [ -n "$LATEST" ] && [ "$RUNNING" != "$LATEST" ]; then
        echo "kernel upgraded ($RUNNING -> $LATEST), rebooting..."
        nohup bash -c 'sleep 5; systemctl reboot' >/dev/null 2>&1 &
        exit 0
      fi
    fi
  SHELL

  NODES.each do |node|
    config.vm.define node[:name] do |vm|
      vm.vm.hostname = node[:name]
      vm.vm.network :private_network, ip: node[:ip]

      vm.vm.provider :libvirt do |libvirt|
        libvirt.cpus = CPUS
        libvirt.memory = MEM_MB
        libvirt.machine_virtual_size = DISK_GB
      end
    end
  end
end
