## 操作系统
* Anolis OS: 23.3
* Kylin OS: v11
* OpenEuler: 24.03
* UOS: V20-1070
* RockyLinux: 9.7
* Ubuntu: 24.04
* Debian: 13.2

## 文件及命令
* config.yaml        集群配置文件
* deploy.sh install  集群部署
* deploy.sh addnode  集群添加节点
* uninstall.sh       集群卸载
* build.sh           离线包构建
* Vagrantfile        测试环境快速构建

## 节点要求
* chrony
* iptables socat ipset nftables

## 集群创建
* 拷贝文件到部署节点
* 修改config.ini文件中node_ip和node_hostname和其它配置
* 配置部署节点root免密登录所有节点
* 执行 ./deploy.sh install

## 节点增加
* 修改config.ini文件中addnode_ip和addnode_hostname
* 执行 ./deploy.sh addnode

## 卸载集群
* 执行 ./uninstall.sh

## 离线包构建
* docker环境
* 执行 ./build.sh           构建config.ini中arch指定架构
* 执行 ./build.sh x86_64    构建x86_64独立离线包
* 执行 ./build.sh aarch64   构建aarch64独立离线包
* 执行 ./build.sh all       构建所有架构独立离线包
* 离线包按架构独立存放在target目录下，包内已固化对应arch

## 软件列表
* etcd                      3.6.14
* kubernetes                1.35.8
* containerd                2.2.1
* cfssl                     1.6.5
* nerdctl                   2.2.2
* k9s                       0.50.18
* coredns                   1.13.1
* calico                    3.31.6
* metrics-server            0.8.1
* local-path-provisioner    0.0.34

## 部署模式
* 前三个节点部署为高可用控制面
* 少于三节点控制面采用非高可用部署