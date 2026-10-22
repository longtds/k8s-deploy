# shellcheck shell=bash
# minio 插件钩子: 安装/卸载的自定义逻辑; 通用步骤由 lib/plugin.sh 引擎完成。
# 可用变量: plugin_dir/plugin_version/plugin_namespace, 可用命令: plugin_kubectl

function plugin_post_install() {
    note "minio 控制台(默认账号 minioadmin/Minio@2026, 请登录后尽快修改口令):
  ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig -n ${plugin_namespace} port-forward svc/minio-console 9001:9001

S3 API 端点(集群内): http://minio.${plugin_namespace}.svc.cluster.local:9000
已预创建 velero 桶; 修改 rootUser/rootPassword 后需同步更新 velero 插件凭据。"
}
