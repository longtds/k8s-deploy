# shellcheck shell=bash
# istio 插件钩子: 安装/卸载的自定义逻辑; 通用步骤由 lib/plugin.sh 引擎完成。
# 可用变量: plugin_dir/plugin_version/plugin_namespace, 可用命令: plugin_kubectl

function plugin_post_install() {
    note "启用命名空间 sidecar 自动注入(按需执行):
  ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig label ns <namespace> istio-injection=enabled

Ingress Gateway(cluster IP, 可按需改为 NodePort):
  ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig -n ${plugin_namespace} get svc istio-ingressgateway

路由治理示例(VirtualService/DestinationRule)与流量策略由 istio CRD 提供, 参考 istio 官方文档。"
}
