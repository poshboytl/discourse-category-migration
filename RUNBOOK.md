# Discourse 分类重构迁移 Runbook

**适用于**：Nervos Talk staging / production
**目的**：把按语言（中/英/西）划分的旧分类压平成 7 个主题分类（Development、Applications & Ecosystem、Announcements & Meta、Theory & Design、Miners Pub、Community Space、General）+ Archived。

**包含 4 个脚本**：
- `recategorize.rb` — 主迁移：建新分类、移帖、删旧分类、归档老帖
- `classify_extract.rb` — 把迁移后留在 General 的活帖导出成 JSONL
- `classify_run.rb` — 调 Claude API 逐条分类，写 CSV
- `classify_migrate.rb` — 按 CSV 把高置信度的帖子搬到对应分类

---

## 0. 前置约定

- Staging 跑在 Discourse 标准 docker container 里。如果不是容器部署，跳过 `./launcher enter app`，直接在 host 跑 `bin/rails`。
- 下面命令默认你已经 `cd /var/discourse && ./launcher enter app` 进入容器。
- 命令里 `discourse` 是 DB 名（容器里通常是这个；裸机环境可能是 `discourse_production`）。先 `echo $DISCOURSE_DB_NAME` 或者 `psql -U postgres -l` 确认实际名字。

## 1. 部署脚本

```bash
# 把 bundle 里的 4 个脚本拷进 Discourse 的 script/ 目录
cp scripts/*.rb /var/www/discourse/script/

# 检查脚本可读
ls -la /var/www/discourse/script/recategorize.rb \
       /var/www/discourse/script/classify_extract.rb \
       /var/www/discourse/script/classify_run.rb \
       /var/www/discourse/script/classify_migrate.rb
```

## 2. 准备 Anthropic API key

API key 通过另外渠道（不在 bundle 里）从开发者拿到，是 `sk-ant-api03-...` 开头的字符串。

**推荐方式：环境变量（不写盘，迁移完关 shell 即销毁）**

```bash
# 用 read -rs 从交互输入读，避免命令进 shell history
read -rs ANTHROPIC_API_KEY   # 粘贴 key，回车
export ANTHROPIC_API_KEY

# 验证
echo "len=${#ANTHROPIC_API_KEY} starts=${ANTHROPIC_API_KEY:0:12}..."
```

⚠️ env var 只在当前 shell 进程内有效。保持同一个 ssh / launcher enter app session 直到 classify_run.rb 跑完。中断后重连需要重新 export。

**备选方式：写文件（持久跨 session，但需要事后清理）**

```bash
mkdir -p /var/www/discourse/ckb
cat > /var/www/discourse/ckb/.anthropic_key <<'EOF'
sk-ant-api03-<YOUR_KEY>
EOF
chmod 600 /var/www/discourse/ckb/.anthropic_key

# 迁移完成后清理：
# rm /var/www/discourse/ckb/.anthropic_key
```

脚本两种都支持，`ENV["ANTHROPIC_API_KEY"]` 优先于文件。

## 3. 备份（不可跳过）

`recategorize.rb --apply` 会改写大量数据，且没有内置回滚。**必须**先备份。

```bash
mkdir -p /shared/backups
# 容器内 PG 默认 peer auth — 用 sudo -u postgres 切 OS 用户，redirect 由 root shell 做
sudo -u postgres pg_dump -Fc discourse > /shared/backups/pre_recategorize_$(date +%Y%m%d_%H%M).dump
ls -lh /shared/backups/pre_recategorize_*.dump
```

无 sudo 时备选：
```bash
su postgres -c 'pg_dump -Fc discourse' > /shared/backups/pre_recategorize_$(date +%Y%m%d_%H%M).dump
```

文件大小应该跟你 staging DB 体积匹配。记下文件路径，回滚时用。

## 4. Dry-run recategorize（只读，30秒-2分钟）

```bash
cd /var/www/discourse
bin/rails runner script/recategorize.rb --dry-run 2>&1 | tee /tmp/recat_dryrun.log
```

**重点检查**：

1. **第 0 步 `VALIDATE sources exist`**：所有 `OK` 行就绪，没有 `MISS`。如果有 `MISS`：
   - 如果同时有"new targets exist"提示 → 是 rerun，正常
   - 如果是首次 + 有 MISS → 停下，抓去 `/tmp/recat_dryrun.log` 给开发者看

2. **第 5 步 `MOVE` 行**：每条形如 `MOVE N topics: 中文 > XXX -> Development`。把 N 加起来心算一下，跟你预估的 staging topic 量对得上。

3. **第 4b 步 `LOCK Community Space`**：dry-run 下显示 `SKIP   Community Space unavailable`，正常（dry-run 不创建分类）。

4. **第 7 步**：dry-run 下全部显示 `KEEP ... not empty`，正常（dry-run 没真移）。

5. **没有 `Aborting` 字样**。

## 5. Apply recategorize（10-30分钟）

```bash
time bin/rails runner script/recategorize.rb --apply 2>&1 | tee /tmp/recat_apply.log
```

⚠️ **不要 ctrl+c**。脚本没有外层事务包裹，强中断会留下半完成状态。如果一定要停，等下一个 `DO topic ...` 边界再发信号。

**完成后必查**：

```bash
# (1) 应该输出 0
grep -cE "^ERROR|Aborting" /tmp/recat_apply.log

# (2) 应该看到 17 个步骤都跑过
grep -E "^ +[0-9]+(\.[0-9]+|[a-z])?\." /tmp/recat_apply.log

# (3) 状态验证
bin/rails runner '
puts "=== Top-level categories ==="
Category.where(parent_category_id: nil).order(:name).each do |c|
  puts "  %-30s id=%-3d topic_count=%d" % [c.name, c.id, c.topic_count]
end
puts ""
puts "=== Community Space lock (must show permission_type=2) ==="
cs = Category.find_by(name: "Community Space", parent_category_id: nil)
abort "Community Space not found" unless cs
CategoryGroup.where(category_id: cs.id).each do |cg|
  puts "  group_id=#{cg.group_id} permission_type=#{cg.permission_type}"
end
puts ""
puts "=== Soft-deleted orphan topics (legacy only; should be small) ==="
puts Topic.unscoped
  .where("deleted_at IS NOT NULL AND category_id IS NOT NULL")
  .where("NOT EXISTS (SELECT 1 FROM categories c WHERE c.id = topics.category_id)")
  .count
'
```

预期：
- 8 个新顶级分类（Announcements & Meta、Development、Applications & Ecosystem、Theory & Design、Miners Pub、Community Space、General、Archived）+ Staff + Nervos Official
- Community Space 那行 `permission_type=2`
- orphan 数字应该接近本地测试值（约 7 左右），即 production 历史遗留

## 6. Extract（只读，1-2分钟）

```bash
mkdir -p /var/www/discourse/ckb

# 清理可能存在的 stale 文件（脚本会拒绝执行 if 它们在）
rm -f /var/www/discourse/ckb/general_classify_in.jsonl \
      /var/www/discourse/ckb/general_classify_out.csv \
      /var/www/discourse/ckb/classify_migrate_audit.csv \
      /var/www/discourse/ckb/classify_migrate_review_needed.csv

bin/rails runner script/classify_extract.rb 2>&1 | tee /tmp/extract.log
```

最后会显示 `Extracting N live topics from General -> ckb/general_classify_in.jsonl`。**记下这个 N**。

## 7. Classify（API 调用，10-20分钟，约 $0.50 成本）

```bash
time bin/rails runner script/classify_run.rb 2>&1 | tee /tmp/classify_run.log
echo "exit=$?"
```

**完成后必查**：

```bash
# (1) Failures 必须 0；exit code 也必须 0
tail -5 /tmp/classify_run.log
# 如果 Failures > 0，重跑这个脚本（resume 模式自动只补失败的）：
#   bin/rails runner script/classify_run.rb
# 直到 Failures=0 才往下走。

# (2) in/out 行数对得上
echo "extracted: $(wc -l < ckb/general_classify_in.jsonl)"
echo "classified: $(($(wc -l < ckb/general_classify_out.csv) - 1))"
# 这两个数字必须相等

# (3) 检查没有 "Community Space" 漏到结果里
ruby -r csv -e '
counts = Hash.new(0)
CSV.foreach("ckb/general_classify_out.csv", headers: true) { |r| counts[r["suggested"]] += 1 }
puts counts.sort_by { |_,v| -v }.map { |k,v| "  %-30s %d" % [k,v] }
abort "FAIL: Community Space appeared as suggested" if counts.key?("Community Space")
'
```

## 8. Dry-run migrate（只读）

```bash
bin/rails runner script/classify_migrate.rb 2>&1 | tee /tmp/migrate_dryrun.log
```

**重点看 Summary**：

```
moved:                    133    ← 这些会真搬
stayed in General:        82     ← 留 General
low-confidence (review):  14     ← 留 General + 写到 review 文件
already moved:            0      ← 应该 0
topic missing:            0      ← 应该 0
invalid category:         0      ← 必须 0（不为 0 见下方故障排查）
```

如果 `invalid category > 0`：

```bash
grep "unknown category" /tmp/migrate_dryrun.log | head -10
```

把输出贴给开发者。一般是 classifier 越权返回了 schema 外的值（理论上不会，schema enum 兜住）。

## 9. Apply migrate（1-3分钟）

```bash
time bin/rails runner script/classify_migrate.rb --apply 2>&1 | tee /tmp/migrate_apply.log
```

**完成后必查**：

```bash
# (1) 0 errors
grep -cE "^ERROR" /tmp/migrate_apply.log

# (2) audit 文件已写盘（行数 = moved + 1 header）
wc -l ckb/classify_migrate_audit.csv

# (3) 低置信度待人工的
wc -l ckb/classify_migrate_review_needed.csv 2>/dev/null

# (4) 最终分类分布
bin/rails runner '
Category.where(parent_category_id: nil).where.not(name: "Nervos Official").order(:name).each do |c|
  total    = Topic.unscoped.where(category_id: c.id, archetype: "regular").count
  live     = Topic.where(category_id: c.id, archetype: "regular", archived: false).count
  archived = Topic.where(category_id: c.id, archetype: "regular", archived: true).count
  puts "  %-30s live=%-4d archived=%-4d total=%d" % [c.name, live, archived, total]
end
'
```

## 10. Browser 冒烟测试

打开 staging 域名，登录普通用户：

- [ ] `/categories` 看到新结构（7 个主题分类 + Archived 灰着）
- [ ] 点进 **Community Space**：右上角**没有** "+ New Topic" 按钮（被锁住了）
- [ ] 点进 **Community Space > Spark Program** 子分类：**有** "+ New Topic" 按钮（子分类不受锁影响）
- [ ] `/latest` 不出现 Archived 里的帖
- [ ] 随便打开一个 Q&A 老帖（应该在 Archived 下）：状态是 read-only（archived）
- [ ] DAO 老帖应该在 **Community Space > CKB Community Fund DAO** 子分类下

## 11. 保留低置信度待人工分流

`ckb/classify_migrate_review_needed.csv` 里是 classifier 信心 <0.7 的 topic，仍在 General。你可以：

- 让管理员人工逐条看，再用 admin UI 移动；
- 或者降阈值再跑：`bin/rails runner script/classify_migrate.rb --apply --min-confidence=0.5`（注意：这会自动信任分类器更多，可能误判增多）。

## 12. 回滚

### 12.1 全量回滚到 apply 前

```bash
# 容器内（peer auth → 切 postgres OS 用户）
sudo -u postgres psql -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='discourse' AND pid != pg_backend_pid();"
sudo -u postgres psql -d postgres -c "DROP DATABASE discourse;"
sudo -u postgres psql -d postgres -c "CREATE DATABASE discourse OWNER discourse;"
sudo -u postgres pg_restore -d discourse -j 4 /shared/backups/pre_recategorize_YYYYMMDD_HHMM.dump
# 重启 Discourse
exit
./launcher restart app
```

### 12.2 只回滚 classify_migrate（不动 recategorize 结果）

```bash
bin/rails runner '
require "csv"
CSV.foreach("ckb/classify_migrate_audit.csv", headers: true) do |row|
  t = Topic.find_by(id: row["topic_id"])
  next unless t
  t.change_category_to_id(row["original_category_id"].to_i, silent: true)
  puts "rolled back #{row["topic_id"]}"
end
'
```

audit CSV 是流式写的——即便 apply 中途崩了，也是真实记录，可以照样回滚。

## 13. 报告回执需要带的东西

跑完之后给开发者看：

1. `/tmp/recat_apply.log` 的最后 50 行 + grep 出的所有 `^ERROR` 行
2. `/tmp/classify_run.log` 最后 5 行（Failures + token usage + cache hit rate）
3. 第 9.4 步的 `bin/rails runner` 最终分布输出
4. 任何看着不对劲的输出

## 14. 故障排查

### `MISS source category` （第 0 步）

某个旧分类名字在 staging 上跟脚本里写的不一样。看 `/tmp/recat_dryrun.log` 里 `MISS` 行，把全名抓给开发者。

### `current transaction is aborted, commands ignored`

通常是 `unaccent` extension 没装。脚本第一步会自动 `CREATE EXTENSION`，正常应该不会出。如果出了，手动：

```bash
sudo -u postgres psql -d discourse -c "CREATE EXTENSION IF NOT EXISTS unaccent;"
```

然后重新从第 4 步开始。

### `Failures: N` 在 classify_run

直接重跑 `bin/rails runner script/classify_run.rb`。它是 resume 模式，只会补缺的 id，不会重复调 API。

### `invalid_category > 0` 在 migrate

理论不该发生（schema enum 限制了 classifier 只能返回 6 个值之一）。如果出现，看 `/tmp/migrate_dryrun.log` 的 `unknown category` 行，把对应 topic id 抓给开发者。

### `permission_type already 2` 在 step 4b 重跑

正常，幂等行为。

---

## 关键改动点（给开发者看）

如果 admin 想知道这套脚本相对最初版本做了什么：

- **soft-deleted topic 不会孤儿化**：step 5 用 `Topic.unscoped` 包含软删除帖子，step 7 destroy 前用 unscoped 检查空
- **age archive 不再波及 Development/Theory/Apps**：step 10 改成显式 include list（General、Announcements & Meta、Community Space、Miners Pub、Archived）
- **Q&A/Grants 直接进 Archived**：不再经 General 中转，避免僵尸归档帖
- **不删除 user-level CategoryUser mute 行**：尊重用户偏好
- **classify_migrate audit 流式写**：apply 中途崩也保留 rollback 记录
- **classify_run 失败非零退出**：stalled or partial 不会被当成 success
- **`--min-confidence` 解析支持空格语法**
- **classify_migrate 启动时校验 in/out id 集合一致**
- **Community Space 锁定为 container-only**：父分类不收新帖，子分类正常工作
