# Admin Cheatsheet — Copy-Paste Runbook

照着从上到下执行，每条命令跑完看 **expect** 行，不对就停，把日志发回开发者。出问题直接看末尾 ROLLBACK。

---

## 0. 进入 Discourse 容器

```bash
# host 上
cd /var/discourse && ./launcher enter app
# 进容器后是 root@..., 默认在 /var/www/discourse
```

后面分两阶段：**root 阶段**做需要写权限的事（部署脚本、备份），然后切到 **discourse 用户**跑 rails。

---

## 1. 部署脚本（root 阶段，在容器里）

```bash
# 1a. 把 4 个脚本放到 /var/www/discourse/script/
#     bundle 假设已经放在 /shared/discourse-category-migration/（host 上 /var/discourse/shared/standalone/）
#     如果你用 docker cp 放在 /root/，把路径改成 /root/discourse-category-migration/
cp /shared/discourse-category-migration/scripts/*.rb /var/www/discourse/script/

# 给 discourse 用户读权限
chown discourse:discourse /var/www/discourse/script/recategorize.rb \
                          /var/www/discourse/script/classify_extract.rb \
                          /var/www/discourse/script/classify_run.rb \
                          /var/www/discourse/script/classify_migrate.rb

# 验证
ls -la /var/www/discourse/script/recategorize.rb \
       /var/www/discourse/script/classify_extract.rb \
       /var/www/discourse/script/classify_run.rb \
       /var/www/discourse/script/classify_migrate.rb
```

**expect**：4 个 .rb 文件出现，owner 是 `discourse`。

---

## 2. 备份（仍在 root 阶段，需要 sudo 切 postgres）

```bash
mkdir -p /shared/backups
# Discourse 容器的 PG 默认 peer auth — 必须切 postgres OS 用户跑 pg_dump，
# redirect 由 root shell 完成（/shared/backups 写权限）
sudo -u postgres pg_dump -Fc discourse > /shared/backups/pre_recategorize_$(date +%Y%m%d_%H%M).dump

ls -lh /shared/backups/pre_recategorize_*.dump
```

如果容器里没 `sudo`：
```bash
su postgres -c 'pg_dump -Fc discourse' > /shared/backups/pre_recategorize_$(date +%Y%m%d_%H%M).dump
```

**expect**：文件出现，体积合理（百 MB 级）。绝对**不是 0 字节**。**记住这个文件名**，回滚用。

---

## 2b. 切到 discourse 用户 + 设 RAILS_ENV + 设 API key（root 阶段结束）

```bash
sudo -iu discourse
cd /var/www/discourse
whoami          # expect: discourse

# 必须显式设成 production；否则 rails 默认走 development，找不到 dev-only gem (debug/prelude) 报错
export RAILS_ENV=production
echo "RAILS_ENV=$RAILS_ENV"

# API key 用环境变量（不写盘）。从交互输入读，不进 shell history。
read -rs ANTHROPIC_API_KEY    # 第 1 次回车 → 静默等待 → 粘贴 key → 第 2 次回车
export ANTHROPIC_API_KEY
echo "len=${#ANTHROPIC_API_KEY} starts=${ANTHROPIC_API_KEY:0:12}..."
```

**expect**：
- `whoami` 输出 `discourse`
- `RAILS_ENV=production`
- 最后一行输出形如 `len=108 starts=sk-ant-api03...`

⚠️ **保持当前 discourse 用户 shell session 直到 step 9 跑完**。如果 ssh 断了或 exit 了：
```bash
# host → 容器
cd /var/discourse && ./launcher enter app
# root → discourse
sudo -iu discourse
cd /var/www/discourse
# 重新 export key（如果还要跑 step 6）
read -rs ANTHROPIC_API_KEY && export ANTHROPIC_API_KEY
```

---

## 3. Dry-run recategorize

```bash
bin/rails runner script/recategorize.rb --dry-run > /tmp/recat_dryrun.log 2>&1
grep -cE "^Aborting|MISS " /tmp/recat_dryrun.log
grep "MOVE " /tmp/recat_dryrun.log
```

**expect**：
- 第一条 grep 输出 **0**（没有 abort、没有 missing source）
- 第二条 grep 列出约 20-30 行 `MOVE   N topics: ...`，加起来 ~2000 个 topic（量级）

不为 0 → 停，把 `/tmp/recat_dryrun.log` 整个发给开发者。

---

## 4. Apply recategorize（10-30 分钟，**不要 ctrl+c**）

```bash
time bin/rails runner script/recategorize.rb --apply > /tmp/recat_apply.log 2>&1
```

⚠️ 这一步把所有输出写进 log 文件，**terminal 期间没有任何输出**——看起来像挂住了，那是正常的。耐心等到 prompt 回来。

如果你想实时看进度，**另开一个 ssh + 容器 + sudo -iu discourse session**，跑：
```bash
tail -f /tmp/recat_apply.log
```

跑完回到 prompt 后：

```bash
grep -cE "^ERROR|Aborting" /tmp/recat_apply.log
tail -3 /tmp/recat_apply.log
```

**expect**：第一条 grep 输出 **0**，第二条 tail 看到 `Done.`。

```bash
# 状态自检
bin/rails runner '
cs = Category.find_by(name: "Community Space", parent_category_id: nil)
abort "FAIL: Community Space missing" unless cs
cg = CategoryGroup.find_by(category_id: cs.id, group_id: 0)
abort "FAIL: Community Space not locked" unless cg && cg.permission_type == 2
puts "OK: Community Space locked (permission_type=2)"
puts "Top-level categories: #{Category.where(parent_category_id: nil).count}"
'
```

**expect**：看到 `OK: Community Space locked (permission_type=2)` 和 `Top-level categories: 10` 左右。

---

## 5. Extract

```bash
mkdir -p ckb
rm -f ckb/general_classify_in.jsonl ckb/general_classify_out.csv ckb/classify_migrate_audit.csv ckb/classify_migrate_review_needed.csv

bin/rails runner script/classify_extract.rb > /tmp/extract.log 2>&1
tail -5 /tmp/extract.log
wc -l ckb/general_classify_in.jsonl
```

**expect**：tail 显示 `Extracting N live topics ...`，wc 数字 = N。**记下 N**。

---

## 6. Classify（10-20 分钟，约 $0.50 成本）

```bash
# 跑之前先确认 API key 还在（step 2b 设的环境变量）
echo "ANTHROPIC_API_KEY len=${#ANTHROPIC_API_KEY}"
# 如果 len=0 或为空，说明 shell 断过；重新 export：
#   read -rs ANTHROPIC_API_KEY
#   export ANTHROPIC_API_KEY

time bin/rails runner script/classify_run.rb > /tmp/classify_run.log 2>&1
echo "exit=$?"
tail -5 /tmp/classify_run.log
```

⚠️ 跑期间 terminal 没输出（全进 log 文件）。想实时看进度，另开 session 跑 `tail -f /tmp/classify_run.log`。

**expect**：
- `exit=0`
- tail 里看到 `Failures: 0`

如果 `Failures` 不是 0 或 `exit` 不是 0，**直接重跑同一条命令**（resume 模式只补缺失的 id）：

```bash
bin/rails runner script/classify_run.rb >> /tmp/classify_run.log 2>&1
echo "exit=$?"
tail -5 /tmp/classify_run.log
```

直到 `Failures: 0` 才走下一步。

---

## 7. Dry-run migrate

```bash
bin/rails runner script/classify_migrate.rb > /tmp/migrate_dryrun.log 2>&1
tail -12 /tmp/migrate_dryrun.log
```

**expect**：tail 输出里 Summary 段 `invalid category: 0`、`topic missing: 0`。
不为 0 → 停，发 `/tmp/migrate_dryrun.log` 给开发者。

---

## 8. Apply migrate（1-3 分钟）

```bash
time bin/rails runner script/classify_migrate.rb --apply > /tmp/migrate_apply.log 2>&1
grep -cE "^ERROR" /tmp/migrate_apply.log
wc -l ckb/classify_migrate_audit.csv
tail -10 /tmp/migrate_apply.log
```

**expect**：grep 输出 **0**，audit csv 行数 = `moved` + 1（header），tail 显示 Summary。

---

## 9. 浏览器冒烟测试

打开 staging 域名，登录普通用户：

- [ ] `/categories` 页面看到新结构（Development、Applications & Ecosystem、Announcements & Meta、Theory & Design、Miners Pub、Community Space、General）
- [ ] 进 **Community Space**：右上角**没有** "+ New Topic" 按钮 ✅ lock 生效
- [ ] 进 **Community Space > Spark Program** 子分类：**有** "+ New Topic" 按钮 ✅ 子分类正常
- [ ] 随便打开一个 Q&A 老帖（在 Archived 分类下）：状态是 read-only ✅

任何一项不对 → 停，截图发开发者。

---

## 10. 完成 — 把这些日志发回开发者

```bash
cd /tmp && tar -czf migration_logs_$(date +%Y%m%d).tar.gz recat_dryrun.log recat_apply.log extract.log classify_run.log migrate_dryrun.log migrate_apply.log /var/www/discourse/ckb/classify_migrate_audit.csv /var/www/discourse/ckb/classify_migrate_review_needed.csv 2>/dev/null
ls -lh /tmp/migration_logs_*.tar.gz
```

把这个 tar.gz 发回开发者就完事。

---

# ROLLBACK（出问题用）

任何一步 ERROR 后，**先别再跑后面的步骤**。回滚到 step 2 备份的状态：

```bash
# 容器内（同样需要切 postgres OS 用户绕过 peer auth）
sudo -u postgres psql -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='discourse' AND pid <> pg_backend_pid();"
sudo -u postgres psql -d postgres -c "DROP DATABASE discourse;"
sudo -u postgres psql -d postgres -c "CREATE DATABASE discourse OWNER discourse;"
sudo -u postgres pg_restore -d discourse -j 4 /shared/backups/pre_recategorize_YYYYMMDD_HHMM.dump
exit  # 退出容器
./launcher restart app
```

替换 `YYYYMMDD_HHMM` 为 step 2 那个备份文件的实际时间戳（`ls /shared/backups/`）。

完成后 staging 回到 apply 前状态。

---

**遇到 bug 或不确定的情况，先停，发日志，不要继续。**
