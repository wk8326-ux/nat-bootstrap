# nanobot-private

nanobot 的私有运维与分发仓库。

## 目的
- 统一保存多节点运维脚本、配置模板、部署骨架、节点文档
- 作为 nanobot 在各服务器之间分发脚本/模板/说明的外部工具仓库
- 降低共享文件夹散落脚本的长期维护成本

## 当前统一约定
- 仓库地址：`git@github-nanobot-private:wk8326-ux/nanobot-private.git`
- 已落地节点：`vps`、`fox`、`aws`、`oracle1`、`oracle4`
- 各节点本地路径：`/opt/nanobot-private`
- 标准更新命令：`cd /opt/nanobot-private && git fetch origin main && git reset --hard origin/main`

## 目录说明
- `scripts/bootstrap/`：新节点初始化、基础依赖、首轮接管脚本
- `scripts/deploy/`：服务部署、同步、更新、回滚脚本
- `scripts/probe/`：探针、节点上报、健康检查相关脚本
- `scripts/maintenance/`：巡检、清理、备份、审计脚本
- `configs/templates/`：通用配置模板（不放明文密钥）
- `configs/nodes/`：节点级配置样板 / 覆盖项示例
- `docs/nodes/`：节点说明、角色、特殊注意事项
- `docs/runbooks/`：可执行操作手册
- `docs/policies/`：仓库内部约束与使用规则
- `state/examples/`：示例状态文件、样例输入输出

## 安全规则
- 不提交私钥、密码、token、真实 `.env`
- 只提交模板、样例、脚本、文档
- 真实密钥继续放在 `/root/local/secret/` 或各节点本地受控路径

## 后续维护原则
- 新增通用脚本，优先放进本仓库而不是散落到共享目录根部
- 多节点共用逻辑，优先脚本化，再由各节点从本仓库拉取
- 节点差异项放到 `configs/nodes/` 或 `docs/nodes/`，不要硬编码到通用脚本
