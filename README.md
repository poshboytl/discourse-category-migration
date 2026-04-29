# Discourse 分类重构迁移

把按语言（中/英/西）划分的 Nervos Talk 旧分类压平成 7 个主题分类（Development、Applications & Ecosystem、Announcements & Meta、Theory & Design、Miners Pub、Community Space、General）+ Archived。

整条流水线由 `scripts/migrate.sh` 一站式跑完，**唯一一次需要人工介入是 apply 之前的 `Type 'yes' to proceed` 确认**。预计耗时 30-60 分钟，约 \$0.50 Claude API 成本，期间 staging 服务不需要停机。

---

## 前置条件

1. **Bundle 在 staging host 上**（`git clone` 或解压 tarball）：
   ```bash
   cd ~
   git clone https://github.com/poshboytl/discourse-category-migration.git
   ```

2. **Bundle 同步到 Discourse 容器看得见的路径**（`/shared/` 在容器里 = host 上 `/var/discourse/shared/standalone/`）：
   ```bash
   sudo rm -rf /var/discourse/shared/standalone/discourse-category-migration
   sudo cp -r ~/discourse-category-migration /var/discourse/shared/standalone/
   ```

3. **Anthropic API key**（dev 通过加密渠道单独发，**不在 bundle 里**），写到容器内文件。

   ⚠️ 下面要**分三段粘贴**——`sudo ./launcher enter app` 会进入容器开新 shell，跟它后面的命令不能一起粘；`read -rs` 会把后续行吞为输入，跟它后面的命令也不能一起粘。

   **3a. 进容器**（host 上跑）：
   ```bash
   cd /var/discourse && sudo ./launcher enter app
   ```
   等到 prompt 变成 `root@xxx-app:/var/www/discourse#`。

   **3b. 准备目录 + 静默读 key**（容器里跑）：
   ```bash
   mkdir -p /var/www/discourse/ckb
   read -rs KEY_INPUT
   ```
   回车后屏幕**静默等待**（看似挂住，正常）→ 粘 API key（不会回显）→ 回车。

   **3c. 写盘 + 收尾**（容器里跑）：
   ```bash
   echo "$KEY_INPUT" > /var/www/discourse/ckb/.anthropic_key && unset KEY_INPUT
   chmod 600 /var/www/discourse/ckb/.anthropic_key
   chown discourse:discourse /var/www/discourse/ckb/.anthropic_key
   ```

   **替代方案**：用环境变量 `export ANTHROPIC_API_KEY='sk-ant-...'`——shell 关掉就消失，每次重跑要重设；但 key 会进 bash history。文件方式更适合反复测试。

---

## 跑迁移

进容器后（root 身份）一条命令：

```bash
bash /shared/discourse-category-migration/scripts/migrate.sh
```

脚本会跑：

1. Pre-flight：检查 root/容器/bundle/API key 设置
2. Step 0：调一次 `/v1/models` 验 API key 真的有效
3. Step 1：部署 4 个 ruby 脚本到 `/var/www/discourse/script/`
4. Step 2：备份 DB 到 `/shared/backups/pre_recategorize_TIMESTAMP.dump`
5. Step 3：跑 `recategorize.rb --dry-run`，把 MOVE 计划列出来
6. **⏸ 停下问 `Type 'yes' to proceed`**：你看一眼 MOVE 计划，输 `yes` 回车
7. Step 4：apply recategorize（10-30 分钟，期间静默）
8. Step 5：自检 Community Space lock 是否生效
9. Step 6：提取 General 活帖给 LLM
10. Step 7：classify_run（10-20 分钟，调 Claude API）
11. Step 8：migrate dry-run（验证 classifier 输出）
12. Step 9：apply migrate（搬最后一批）
13. Step 10：把所有 log + audit CSV 打包成 `/tmp/migration-logs-TIMESTAMP.tar.gz`

完成后会打印：
- backup 文件路径（万一回滚用）
- log bundle 路径（要发给 dev）
- 浏览器冒烟测试 checklist

---

## 完成后必做

### 1. 浏览器冒烟测试

打开 staging 域名，**用普通用户账号**登录（不是 admin），检查：

- [ ] `/categories` 看到 8 个顶级（7 主题 + Archived + Staff）
- [ ] 进 **Community Space** 顶级：右上角**没有** "+ New Topic" 按钮
- [ ] 进 **Community Space > Spark Program**：**有** "+ New Topic"
- [ ] 进 **Community Space > CKB Community Fund DAO**：**有** "+ New Topic"
- [ ] `/latest` 不显示 Archived 里的帖子
- [ ] 老 Q&A 帖在 Archived 分类、状态 read-only

### 2. 把 log bundle 发回 dev

```bash
# 容器里
cp /tmp/migration-logs-*.tar.gz /shared/
exit

# host 上
scp /var/discourse/shared/standalone/migration-logs-*.tar.gz dev_user@dev_host:~/
```

或任何渠道（邮件 / Slack / 网盘）。

**在 dev sign-off 之前不要清备份、不要重启服务、不要宣布迁移完成。**

### 3. 安全清理

迁移成功后：

```bash
# 容器里
rm /var/www/discourse/ckb/.anthropic_key

# 然后去 https://console.anthropic.com/settings/keys 把这个 key revoke
```

`/shared/backups/pre_recategorize_*.dump` 保留**至少 1 周**，期间如果发现问题还能回滚。一周后再清。

---

## 出错怎么办

`migrate.sh` 任意一步**红色 FAIL**：

- ❌ 不要自己 retry
- ❌ 不要改 staging 上的脚本/数据
- ✅ 把整段 terminal 输出 + log bundle 截图/打包发给 dev
- ✅ 等 dev 答复

### 回滚到迁移前状态

```bash
bash /shared/discourse-category-migration/scripts/rollback.sh \
  /shared/backups/pre_recategorize_<TIMESTAMP>.dump
```

输入 `rollback` 确认。完成后 `exit` 容器，host 上 `cd /var/discourse && sudo ./launcher restart app`。

---

## 高级用法：手动分步

如果出于任何原因不能用 `migrate.sh` 一站式跑（比如要在每一步之间停下来人工检查），看 [STEP_BY_STEP.md](STEP_BY_STEP.md)——同一套逻辑拆成 13 步手动命令。
