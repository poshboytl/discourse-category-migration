# Quickstart — 一站式迁移

如果只想运行迁移、不关心步骤细节，照这个文档来。整条流水线由 `migrate.sh` 自动跑，唯一的人工确认在 `apply` 之前。

详细分步与故障排查参考 `CHEATSHEET.md` / `RUNBOOK.md`。

---

## 0. 前置条件（必须先满足）

- [ ] **Bundle 在 staging host 上**（如 `~/discourse-category-migration.tar.gz`，已解压）
- [ ] **Anthropic API key**（开发者通过加密渠道单独发，不在 bundle 里）

## 1. 把 bundle 移到容器可见的路径

在 staging host 上：

```bash
# 假设 bundle 已经解压在 ~/discourse-category-migration/
sudo cp -r ~/discourse-category-migration /var/discourse/shared/standalone/
```

容器内 `/shared/discourse-category-migration/` 就是上面这个路径。

## 2. 进容器 + export API key + 跑脚本

```bash
# host: 进容器
cd /var/discourse && sudo ./launcher enter app

# 容器（默认 root 身份）：export API key（从交互输入读，不进 history）
read -rs ANTHROPIC_API_KEY     # 静默等待 → 粘贴 key → 回车
export ANTHROPIC_API_KEY

# 跑迁移脚本
bash /shared/discourse-category-migration/scripts/migrate.sh
```

脚本会：

1. 检查环境（root、容器、bundle、API key）
2. 部署 4 个 ruby 脚本到 `/var/www/discourse/script/`
3. 备份 DB 到 `/shared/backups/pre_recategorize_TIMESTAMP.dump`
4. 跑 dry-run，把 MOVE 计划印出来
5. **唯一一次确认**：你看到计划，输入 `yes` 才继续
6. apply recategorize（10-30 分钟）
7. 验证 Community Space 锁就位
8. extract → classify（调 Claude API） → migrate dry-run → migrate apply
9. 把所有 log 打包成 `/tmp/migration-logs-TIMESTAMP.tar.gz`

总耗时约 30-60 分钟。期间脚本中途没问题就一路绿色 OK 走到底；任何一步红色 FAIL 就停下，告诉你 log 在哪。

## 3. 完成后

`migrate.sh` 末尾会打印：

- backup 文件路径（回滚用）
- log bundle 路径（发回开发者）
- 浏览器冒烟测试 checklist

按 checklist 验证 staging 域名上：

- [ ] `/categories` 看到新结构
- [ ] Community Space 顶级**没有** "+ New Topic" 按钮
- [ ] Community Space > Spark Program 子分类**有** "+ New Topic" 按钮
- [ ] 老 Q&A 帖在 Archived 分类、状态 read-only

## 4. 出问题就回滚

```bash
bash /shared/discourse-category-migration/scripts/rollback.sh \
  /shared/backups/pre_recategorize_TIMESTAMP.dump
```

输入 `rollback` 确认，drops 当前 DB 并从备份恢复。完成后 `exit` 容器、`./launcher restart app`。

---

## 故障速查

| 现象 | 处置 |
|---|---|
| `must run as root` | `./launcher enter app` 后默认就是 root，重新进 |
| `bundle scripts not found` | bundle 没放对地方，确认 `/shared/discourse-category-migration/scripts/*.rb` 存在 |
| `ANTHROPIC_API_KEY env var not set` | 重 export：`read -rs ANTHROPIC_API_KEY && export ANTHROPIC_API_KEY` |
| `backup is 0 bytes` | postgres 没启动或 peer auth 异常，看脚本 stderr |
| `dry-run has N aborting/missing lines` | 旧分类名字跟脚本预设不匹配，看 `recat_dryrun.log` 给开发者 |
| `classification still has failures after 3 attempts` | API 持续报错，把 `classify_run.log` 给开发者 |

任何 FAIL 处的 log 文件都在 `/tmp/migration-TIMESTAMP/` 下。
