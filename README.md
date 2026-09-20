# PDS Lab 1

`pds-lab-1` 是 **PDS-Bridge v0.02 Golden Lab** 的第一座练习场。

这个仓库故意保持极简，用来验证一条真实的软件开发闭环：

```text
Human
  -> ChatGPT Web
  -> remote pds-mcp
  -> PDS-Bridge
  -> CTO
  -> Task
  -> Worker
  -> code / evidence
  -> GitHub PR
  -> acceptance
```

## Purpose

这里不是一个需要人工持续维护的正式产品仓库。

它的主要用途是观察和验证：

- ChatGPT 是否能够通过 MCP 与 PDS-Bridge 交互；
- CTO 是否能够把自然语言需求转化成结构化 Task；
- Decision Gate 是否正确区分“需要人决策”和“可以执行”的工作；
- PDS-Bridge 是否能够选择合适的 Worker；
- Worker 是否只在允许的 workspace 和 scope 内执行；
- 运行过程是否能够产生可靠 evidence；
- GitHub 是否能够完整保存 Issue、branch、commit、PR、evidence 和 acceptance 历史。

## First Golden Run

第一次实验计划让用户通过 ChatGPT 提出一个非常简单的前端页面需求。

当前实验映射：

- CTO：Codex
- Worker：agy
- Alternate Worker：OpenCode
- Runtime：PDS-Bridge
- Durable Project Memory：GitHub

具体 Agent 产品只是当前实现，PDS-Bridge 的 Task 和权限模型不应依赖这些产品名。

## Repository rule

这个 README 是仓库的 **seed commit**。

从此之后，Golden Run 产生的页面代码、任务分支、提交、Pull Request 和运行记录，应尽量通过 PDS-Bridge 工作流产生，而不是人工提前写入。

Worker 不应拥有项目级决策或调度权限。理想流程是：

```text
PDS-Bridge prepares task / branch
        |
        v
Worker edits and validates
        |
        v
PDS-Bridge collects evidence
        |
        v
PDS-Bridge records Git / GitHub history
        |
        v
CTO accepts or rejects
```

## Success criteria

当一次简单前端需求能够从 ChatGPT 发起，并最终在本仓库留下可追溯的：

```text
Issue
 -> Task
 -> Worker Run
 -> Commit
 -> Pull Request
 -> Evidence
 -> CTO Acceptance
```

即视为 PDS-Bridge v0.02 Golden Lab 的核心实验成功。

---

This repository is intentionally minimal. The interesting part is not the page itself; it is the development process that creates it.
