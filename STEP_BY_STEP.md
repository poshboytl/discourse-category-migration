# 手动分步执行

跟 `scripts/migrate.sh` 做的事一模一样，只是拆成 13 步手动跑——适合：

- 想在每一步之间停下来人工 review 输出再继续
- 出过错、要从中间某一步接着跑
- 容器环境跟脚本假设不一致，想绕开 wrapper 直接调 ruby 脚本

**前置条件跟 README 一样**：bundle 同步到 `/var/discourse/shared/standalone/`、API key 配好、容器内 root 身份。

下面所有命令都假设你已经 `cd /var/discourse && sudo ./launcher enter app` 进入容器，prompt 是 `root@.../var/www/discourse#`。

每一步开头列出"对应 migrate.sh 哪一段"，方便交叉对比。

---

## Pre-flight：环境检查

对应 migrate.sh 的 `Pre-flight checks` 段。

```bash
# 必须 root
[[ "$(id -u)" -eq 0 ]] && echo OK_root || echo FAIL_not_root

# bundle 必须在 /shared 下
[[ -d /shared/discourse-category-migration/scripts ]] && echo OK_bundle || echo FAIL_bundle_missing

# discourse 应用目录必须存在
[[ -d /var/www/discourse ]] && echo OK_discourse_dir || echo FAIL_no_discourse

# discourse 和 postgres 用户必须存在
id discourse >/dev/null 2>&1 && echo OK_discourse_user
id postgres >/dev/null 2>&1 && echo OK_postgres_user

# curl 必须有
command -v curl >/dev/null 2>&1 && echo OK_curl
```

5 个 `OK_*` 全部出现就过。

**API key**：检查 env 或文件有一处可用：

```bash
# 看 env 有没有
echo "len=${#ANTHROPIC_API_KEY:-0}"

# 没有的话用文件
ls -la /var/www/discourse/ckb/.anthropic_key 2>/dev/null

# 文件不存在就写一个：
mkdir -p /var/www/discourse/ckb
read -rs KEY_INPUT && echo "$KEY_INPUT" > /var/www/discourse/ckb/.anthropic_key && unset KEY_INPUT
chmod 600 /var/www/discourse/ckb/.anthropic_key
chown discourse:discourse /var/www/discourse/ckb/.anthropic_key

# 然后 export 到当前 shell 用于 step 0 ping
export ANTHROPIC_API_KEY=$(cat /var/www/discourse/ckb/.anthropic_key)
```

---

## Step 0：验 API key 有效

对应 migrate.sh 的 `0. Validate Anthropic API key`。

```bash
curl -sS -o /dev/null -w "HTTP %{http_code}\n" \
  --max-time 15 \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  https://api.anthropic.com/v1/models
```

**expect**：`HTTP 200`。

- `HTTP 401` / `HTTP 403` → key 无效或 revoked，去 console 拿新 key 重设
- `HTTP 000` → 网络不通
- 其他 → 可能是临时问题，可以继续，classify 阶段会 retry

---

## Step 1：部署 ruby 脚本

对应 migrate.sh 的 `1. Deploy migration scripts`。

```bash
for f in recategorize.rb classify_extract.rb classify_run.rb classify_migrate.rb; do
  cp /shared/discourse-category-migration/scripts/$f /var/www/discourse/script/$f
  chown discourse:discourse /var/www/discourse/script/$f
  chmod 644 /var/www/discourse/script/$f
done

ls -la /var/www/discourse/script/{recategorize,classify_extract,classify_run,classify_migrate}.rb
```

**expect**：4 个文件，owner `discourse:discourse`。

---

## Step 2：备份 DB

对应 migrate.sh 的 `2. Backup DB`。

```bash
mkdir -p /shared/backups
TS=$(date +%Y%m%d_%H%M%S)

sudo -u postgres pg_dump -Fc discourse > /shared/backups/pre_recategorize_${TS}.dump

ls -lh /shared/backups/pre_recategorize_${TS}.dump
```

**expect**：文件几百 MB，**绝对不是 0 字节**。**记下文件名**，回滚要用。

如果 0 字节或几 KB，**停下**——pg_dump 静默失败了，看 stderr。

---

## Step 3：dry-run recategorize

对应 migrate.sh 的 `3. Dry-run recategorize`。

为方便后续 step 4-9 复用，先定义个 helper（discourse 用户身份跑 rails）：

```bash
DISCOURSE_RUN() {
  sudo -u discourse env RAILS_ENV=production "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" \
    bash -c "cd /var/www/discourse && $*"
}
```

跑 dry-run：

```bash
DISCOURSE_RUN "bin/rails runner script/recategorize.rb --dry-run" 2>&1 | tee /tmp/recat_dryrun.log

grep -cE "^Aborting|MISS " /tmp/recat_dryrun.log
grep "^  MOVE " /tmp/recat_dryrun.log
```

**expect**：
- 第一个 grep 输出 **0**（没有 abort、没有 missing source）
- 第二个 grep 列出 ~20 行 MOVE 计划，加起来 ~2000 个 topic

如果有 abort/miss，**停下**，把 log 发回 dev。

---

## ⏸ 确认 gate

对应 migrate.sh 的 `Confirmation gate`。

**人工 checkpoint**：

- 上面 MOVE 计划合理吗？数量级跟你估的一致吗？
- backup 文件在 `/shared/backups/` 下，体积合理吗？
- 准备好了不能 ctrl+c 的 step 4 / step 9 吗？

确认 OK 再继续。**不 OK 现在就停**——什么都没改 DB。

---

## Step 4：apply recategorize

对应 migrate.sh 的 `4. Apply recategorize`。**10-30 分钟，不要 ctrl+c**。

```bash
time DISCOURSE_RUN "bin/rails runner script/recategorize.rb --apply" > /tmp/recat_apply.log 2>&1

grep -cE "^ERROR|Aborting" /tmp/recat_apply.log
tail -3 /tmp/recat_apply.log
```

**expect**：
- 第一个 grep 输出 **0**
- tail 看到 `Done.`

期间想看进度，**另开一个 ssh + 容器 shell** 跑 `tail -f /tmp/recat_apply.log`。

---

## Step 5：自检 Community Space lock

对应 migrate.sh 的 `5. Verify post-apply state`。

```bash
DISCOURSE_RUN 'bin/rails runner "
cs = Category.find_by(name: %q(Community Space), parent_category_id: nil)
abort %q(Community Space missing) unless cs
cg = CategoryGroup.find_by(category_id: cs.id, group_id: 0)
abort %q(Community Space not locked) unless cg && cg.permission_type == 2
puts %q(OK: Community Space locked)
puts %q(Top-level categories: ) + Category.where(parent_category_id: nil).count.to_s
"'
```

**expect**：
- `OK: Community Space locked`
- `Top-level categories: 10`（约这个数量）

---

## Step 6：提取 General 活帖

对应 migrate.sh 的 `6. Extract`。

```bash
DISCOURSE_RUN "rm -f ckb/general_classify_in.jsonl ckb/general_classify_out.csv ckb/classify_migrate_audit.csv ckb/classify_migrate_review_needed.csv && bin/rails runner script/classify_extract.rb" > /tmp/extract.log 2>&1

tail -5 /tmp/extract.log
wc -l /var/www/discourse/ckb/general_classify_in.jsonl
```

**expect**：tail 显示 `Extracting N live topics`，wc 数字 = N。**记下 N**。

---

## Step 7：classify via Claude API

对应 migrate.sh 的 `7. Classify`。**10-20 分钟，~\$0.50**。

```bash
DISCOURSE_RUN "bin/rails runner script/classify_run.rb" > /tmp/classify_run.log 2>&1
echo "exit=$?"
tail -5 /tmp/classify_run.log
```

**expect**：
- `exit=0`
- tail 看到 `Failures: 0`

如果 `Failures > 0` 或 `exit != 0`：

```bash
# 直接重跑——resume 模式只补缺失 id
DISCOURSE_RUN "bin/rails runner script/classify_run.rb" >> /tmp/classify_run.log 2>&1
echo "exit=$?"
tail -5 /tmp/classify_run.log
```

直到 `Failures: 0` 才走下一步。

---

## Step 8：dry-run migrate

对应 migrate.sh 的 `8. Dry-run migrate`。

```bash
DISCOURSE_RUN "bin/rails runner script/classify_migrate.rb" > /tmp/migrate_dryrun.log 2>&1
tail -12 /tmp/migrate_dryrun.log
```

**expect** Summary 段：
- `invalid category: 0` ← 必须 0
- `topic missing: 0`   ← 必须 0
- `moved: N`           ← 这些会真搬

不为 0 就停下发 log。

---

## Step 9：apply migrate

对应 migrate.sh 的 `9. Apply migrate`。**1-3 分钟**。

```bash
time DISCOURSE_RUN "bin/rails runner script/classify_migrate.rb --apply" > /tmp/migrate_apply.log 2>&1
echo "exit=$?"
grep -cE "^ERROR" /tmp/migrate_apply.log
wc -l /var/www/discourse/ckb/classify_migrate_audit.csv
tail -10 /tmp/migrate_apply.log
```

**expect**：
- `exit=0`
- grep ERROR = **0**
- audit csv 行数 = `moved` + 1（header）

---

## Step 10：打包 logs

对应 migrate.sh 的 `10. Bundle logs`。

```bash
TS=$(date +%Y%m%d_%H%M%S)
LOG_DIR=/tmp/migration-${TS}
mkdir -p $LOG_DIR
cp /tmp/recat_dryrun.log /tmp/recat_apply.log /tmp/extract.log /tmp/classify_run.log /tmp/migrate_dryrun.log /tmp/migrate_apply.log $LOG_DIR/
cp /var/www/discourse/ckb/classify_migrate_audit.csv $LOG_DIR/ 2>/dev/null
cp /var/www/discourse/ckb/classify_migrate_review_needed.csv $LOG_DIR/ 2>/dev/null

tar -czf /tmp/migration-logs-${TS}.tar.gz -C /tmp migration-${TS}
ls -lh /tmp/migration-logs-${TS}.tar.gz
```

把这个 tar.gz 发回 dev。

---

## 完成后

跟 README §"完成后必做"一样：

1. 浏览器冒烟测试 7 项
2. 把 log bundle 发回 dev，等 sign-off
3. 安全清理（`rm /var/www/discourse/ckb/.anthropic_key`、console 上 revoke key）
4. backup 保留 1 周

---

## 中途出错怎么 resume

每一步都是"上一步成功才能往下"，所以中途某一步红 / 异常：

| 失败步骤 | 是否破坏 DB | 修了之后从哪里接着 |
|---|---|---|
| Pre-flight / Step 0-1 | 没 | 修完从同一步重跑 |
| Step 2 backup | 没（pg_dump 是只读） | 重跑同一步 |
| Step 3 dry-run | 没 | 修完重跑 |
| Step 4 apply | **是**——半完成状态 | 看 recat_apply.log 末尾，决定回滚 vs 继续。recategorize.rb 自身幂等，可以重跑同一步把剩下的补完 |
| Step 5 sanity check | 没 | 看哪个 abort 信息触发，可能要回滚到 step 2 |
| Step 6 extract | 没（rm 的是上次的 csv，不影响 DB） | 重跑同一步 |
| Step 7 classify | 没（CSV 是中间产物） | 重跑同一步，resume 模式只补缺失 |
| Step 8 dry migrate | 没 | 修完重跑 |
| Step 9 apply migrate | **是**——可能搬了一部分 topic | 重跑同一步，classify_migrate.rb 检查 `category_id != general.id` 跳过已搬走的，幂等 |

完全回滚：`bash /shared/discourse-category-migration/scripts/rollback.sh /shared/backups/pre_recategorize_<TIMESTAMP>.dump`
