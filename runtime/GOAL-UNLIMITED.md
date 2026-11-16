# 持久 Goal 自动轮次

本运行时的 Web overlay 把新建 Goal 的 `defaultMaxGoalRounds` 设为 `unlimited`。已有有限上限的 Goal 不会自动改变；取消、模型单次输出上限、工具安全超时和并发限制不受影响。进程恢复后仍须用户授权恢复 Goal。

`goal-unlimited.diff` 按 `pins.json` 锁定 DSH 0.2.2-rc.1；新的无限 Goal 持久记录不能由未打补丁的旧引擎读取。回退前保留原始数据和升级前备份，并隔离升级后创建或编辑为无限的会话；不要用旧引擎打开这些会话。有限数字记录仍可由新引擎读取。

ARM64 个人测试运行时使用现有 Ubuntu 26.04.1／PRoot 5.1.107.102 基线，输入 rootfs SHA-256 `fc27c951ba23f8ffaba69ff376cf51d9826aeda82034c79cf1f09fa351700df8`；复用其升级 baseId、Python、系统文件与用户数据迁移规则，仅在独立 staging 应用裁剪版八文件补丁、追加 Web overlay、更新 runtime 元数据并重新打包。仓库默认 `build-runtime.sh` 的 Ubuntu 24.04 配方不是该 ARM64 资产的重建入口，不得用其覆盖 26.04 用户根文件系统。
