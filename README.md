# Discourse 分类重构迁移 Bundle

把按语言（中/英/西）划分的 Nervos Talk 旧分类压平成 7 个主题分类。

## 文件清单

```
.
├── README.md             ← 本文件（先看）
├── QUICKSTART.md         ← 一站式自动脚本（admin 主用这个）
├── CHEATSHEET.md         ← 手动分步执行（要逐步控制时用）
├── RUNBOOK.md            ← 详细原理 + 故障排查（出问题查这个）
└── scripts/
    ├── migrate.sh            ← 一站式迁移 wrapper
    ├── rollback.sh           ← 回滚 wrapper
    ├── recategorize.rb       ← Ruby: 主迁移
    ├── classify_extract.rb   ← Ruby: 导出 General 活帖
    ├── classify_run.rb       ← Ruby: 调 Claude API 分类
    └── classify_migrate.rb   ← Ruby: 按分类结果搬帖
```

## 给 Admin

**直接看 `QUICKSTART.md`**——5 步流程，全程一条 `bash migrate.sh`，唯一确认在 apply 前。预计 30-60 分钟。

如果想**手动一步步控制**（在每一步之间可以暂停、看输出、决定是否继续），看 `CHEATSHEET.md`。

如果哪一步**报错或行为意外**，看 `RUNBOOK.md` 的故障排查段。

## API key

不在 bundle 里。开发者通过加密渠道（1Password / Signal / Keybase）单独发给你。是 `sk-ant-api03-...` 开头的字符串。

通过环境变量传给脚本，**不写入磁盘**——shell 关闭即销毁，迁移完无需手动清理。

## 总耗时

约 30-60 分钟（取决于 topic 量），其中：

- 备份：30 秒-2 分钟
- Apply recategorize：10-30 分钟
- Classify（API 调用）：10-20 分钟，约 $0.50 成本
- Apply migrate：1-3 分钟
- 其他（dry-run、自检、打包 log）：< 5 分钟

期间 staging 服务**不需要停机**。

## 回滚

`migrate.sh` 第 2 步会自动备份。任何时候若发现迁移结果有问题：

```bash
bash /shared/discourse-category-migration/scripts/rollback.sh \
  /shared/backups/pre_recategorize_<TIMESTAMP>.dump
```

输入 `rollback` 确认即可。

## 改动了什么数据

- 重建 7 个顶级分类 + Archived
- 移动约 2000 个 topic 到新分类
- 删除约 27 个旧的源分类（按语言划分的）
- 把 >2 年没活动的 topic 在指定分类里设为 archived（read-only）
- 调整 sidebar 默认分类、muted 分类等 site setting
- Community Space 顶级 lock 成 container-only（直接发帖被禁，子分类正常）

## 不改动什么

- 不改 user 数据（无 user-level CategoryUser 行删除）
- 不改 post 内容
- 不删 topic（仅 archived/移动）
- 不改 plugin 配置
