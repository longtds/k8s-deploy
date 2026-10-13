# shellcheck shell=bash
# prometheus 插件钩子: 安装/卸载的自定义逻辑; 通用步骤由 lib/plugin.sh 引擎完成。
# 可用变量: plugin_dir/plugin_version/plugin_namespace, 可用命令: plugin_kubectl

function plugin_post_install() {
    note "Grafana 访问方式:
  ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig port-forward -n ${plugin_namespace} svc/kps-grafana 3000:80
  浏览器打开 http://127.0.0.1:3000  初始账号: admin / prom-operator (建议尽快修改)

Prometheus Web:
  ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig port-forward -n ${plugin_namespace} svc/kps-prometheus 9090:9090
  浏览器打开 http://127.0.0.1:9090

采集对象由 prometheus-operator 自动管理(node-exporter/kubelet/coredns/组件自身)。"
}
