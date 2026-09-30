## 操作系统
* Anolis OS: 23.3
* Kylin OS: v11
* OpenEuler: 24.03
* UOS: V20-1070
* RockyLinux: 9.7
* Ubuntu: 24.04
* Debian: 13.2

## 文件及命令
* config.ini              集群配置文件
* deploy.sh install       集群部署
* deploy.sh addnode       集群添加节点
* uninstall.sh            集群卸载(仅初始节点)
* uninstall.sh all        集群卸载(含 addnode 节点)
* build.sh                离线包构建
* Vagrantfile             测试环境快速构建

## 目录结构
* deploy.sh/build.sh/uninstall.sh 为入口，仅负责参数解析与执行流程编排
* lib/ 按功能拆分函数库：common 输出与全局选项、remote 远程操作、preflight 预检、
  system 系统调优、certs 证书、control-plane 控制面组件、node 节点组件、addons 集群插件、
  build-* 构建阶段、uninstall 卸载阶段
* config.ini 被各脚本 source，脚本须在仓库根目录执行

## 节点要求
* 必需(缺失则中止安装): iptables socat ipset conntrack ip
* nftables: 仅kubeproxy_mode=nftables时必需，且内核需 >= 5.13，缺失会导致kube-proxy无法启动
* chrony: 可选，缺失仅告警并跳过时间同步
* deploy.sh install/addnode会预检以上依赖及kubeproxy_mode、内核版本
* 安装示例
  * rhel系: dnf install -y nftables iptables-nft socat ipset conntrack-tools iproute chrony
  * debian系: apt install -y nftables iptables socat ipset conntrack iproute2 chrony
  * 注: iproute/iproute2 提供二进制 ip

## 集群创建
* 拷贝文件到部署节点
* 修改config.ini文件中node_ip和node_hostname和其它配置
* kubeproxy_mode选择iptables或nftables(默认nftables, 节点内核需 >= 5.13)
* 配置部署节点root免密登录所有节点
* 执行 ./deploy.sh install

## bootstrap token
* config.ini中kube_token留空时，首次install自动生成随机token并保存到pki/kube_token
* 后续install/addnode复用该文件中的token，uninstall后文件删除，重新install会再生成
* 如需自定义token，在config.ini中显式设置kube_token即可（注意勿使用公开已知的值）

## 节点增加
* 修改config.ini文件中addnode_ip和addnode_hostname
* 执行 ./deploy.sh addnode

## 卸载集群
* 执行 ./uninstall.sh       卸载初始节点(删除本机pki/、admin.kubeconfig、hosts)
* 执行 ./uninstall.sh all   同时卸载 addnode 节点

## 离线包构建
* docker环境
* 执行 ./build.sh           构建config.ini中arch指定架构
* 执行 ./build.sh x86_64    构建x86_64独立离线包
* 执行 ./build.sh aarch64   构建aarch64独立离线包
* 执行 ./build.sh all       构建所有架构独立离线包
* 离线包按架构独立存放在target目录下，包内已固化对应arch

## 软件列表(版本以config.ini为准)
* etcd                      3.6.14
* kubernetes                1.35.8
* containerd                2.2.1   (随nerdctl-full捆绑)
* nerdctl                   2.2.2
* cfssl                     1.6.5
* k9s                       0.50.18
* calico                    3.31.6
* coredns                   1.13.1
* metrics-server            0.8.1
* local-path-provisioner    0.0.34
* registry                  2.8.3   (私有镜像仓库, 部署于首节点:5000)
* haproxy                   3.2.13  (三master时的apiserver本地代理)
* pause                     3.10.1

## 部署模式
* 前三个节点部署为高可用控制面
* 少于三节点控制面采用非高可用部署
