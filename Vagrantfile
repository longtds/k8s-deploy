# -*- mode: ruby -*-
# vi: set ft=ruby :

# 测试矩阵参数
# BOX = "cloud-image/ubuntu-24.04"
# BOX = "cloud-image/ubuntu-22.04"
# BOX = "cloud-image/rocky-10"
BOX = "cloud-image/rocky-9"

CPUS = 4
MEM_MB = 4096
DISK_GB = 100

# 3-node cluster: consecutive IPs
NODES = [
  { name: "node1", ip: "192.168.121.11" },
  { name: "node2", ip: "192.168.121.12" },
  { name: "node3", ip: "192.168.121.13" },
]

# 部署机公钥: deploy.sh 以 root + 私钥 SSH 各节点
root_pubkey = File.read(File.expand_path("~/.ssh/id_ed25519.pub")).strip

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

    # 4. Validate the configuration before reloading sshd
    sshd -t
    systemctl reload sshd
    echo "root access configured"
  SHELL

  # Install prerequisites listed in README.md
  config.vm.provision "install-deps", type: "shell", inline: <<-SHELL
    set -euo pipefail

    if command -v dnf &>/dev/null; then
      # rhel系 (rocky/anolis/openeuler/uos/kylin)
      dnf install -y nftables iptables-nft socat ipset conntrack-tools iproute chrony
    elif command -v apt-get &>/dev/null; then
      # debian系 (ubuntu/debian)
      apt-get update
      apt-get install -y nftables iptables socat ipset conntrack iproute2 chrony
    else
      echo "ERROR: unsupported OS, neither dnf nor apt-get found" >&2
      exit 1
    fi
    echo "prerequisites installed"
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
