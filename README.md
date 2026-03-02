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
* 执行 ./build.sh
* 离线包存放在target目录下

## 软件列表
* etcd                      3.6.x
* kubernetes                1.35.x
* containerd                2.x
* cfssl                     1.6.x
* nerdctl                   2.x
* k9s                       0.50.x
* coredns                   1.13.x
* calico                    3.31.x
* metrics-server            0.8.x
* local-path-provisioner    0.0.32

## 部署模式
* 前三个节点部署为高可用控制面
* 少于三节点控制面采用非高可用部署