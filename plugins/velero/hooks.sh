# shellcheck shell=bash
# velero 插件钩子: 安装/卸载的自定义逻辑; 通用步骤由 lib/plugin.sh 引擎完成。
# 可用变量: plugin_dir/plugin_version/plugin_namespace, 可用命令: plugin_kubectl

# velero 依赖 minio 插件提供 S3 备份后端
function plugin_pre_install() {
    if ! plugin_kubectl -n minio get svc minio >/dev/null 2>&1; then
        _plugin_fail "velero depends on the minio plugin (S3 backup storage backend); install it first: ./deploy.sh plugin install minio" || return 1
        return 1
    fi
}

function plugin_post_install() {
    note "备份/恢复通过 velero CRD 操作(离线包未内置 velero CLI), 立即备份示例:
  kubectl apply -f - <<EOF
  apiVersion: velero.io/v1
  kind: Backup
  metadata:
    name: backup-example
    namespace: ${plugin_namespace}
  spec:
    includedNamespaces: ['default']
    storageLocation: default
    ttl: 168h
  EOF
定时备份使用 Schedule CR(spec.schedule 为 cron 表达式, 如 '0 2 * * *')。
备份数据位于 minio 插件的 velero 桶; 修改 minio 口令后需同步更新本插件 secret 的 cloud 键。"
}
