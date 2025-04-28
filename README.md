### 推荐操作系统版本
* Anolis OS: 23.2
* Kylin OS: v10 SP3
* openKylin 2.0 SP1
* OpenEuler: 24.03 SP1
* RockyLinux: 9.5
* Ubuntu: 24.04
* Debian: 12


### 软件列表
* etcd：3.5.21
* kubernetes：1.32.4
* containerd: 1.7.27
* cfssl: 1.6.5
* nerdctl: 2.0.4


### 插件列表
* coredns: 1.14.0
* flannel: 0.26.7
* metrics-server: 0.7.2
* local-path-provisioner: 0.0.31
* cilium: 1.17.3
* longhorn: 1.8.1


### 节点要求
* chrony (ntp)
* iptables socat ipset ipvsadm conntrack (ipvs)
* open-iscsi bash curl findmnt grep awk blkid lsblk (longhorn)


### 创建集群
* 拷贝文件到部署节点
* 修改文件中node_ip和node_hostname和其它相关配置
* 配置部署节点root免密登录所有节点
* 执行./deploy.sh install 开始部署


### 增加节点
* 修改文件中addnode_ip和addnode_hostname
* 执行./deploy.sh addnode为集群添加节点


### 卸载集群
* 执行./uninstall.sh 卸载集群


### cilium系统要求
* Hosts with either AMD64 or AArch64 architecture
* Linux kernel >= 4.19.57
* RHEL 8+
* CentOS 8+
* RockyLinux 8+
* Ubuntu 20.04+
* Debian 10+


### 其它说明
* 节点数量不受限制
* 低于3节点master无HA

### 文件及命令说明
* config.yaml        集群配置文件
* deploy.sh install  集群部署
* deploy.sh addnode  集群添加节点
* uninstall.sh       集群卸载
* build.sh           离线包构建
* Vagrantfile        测试环境快速构建