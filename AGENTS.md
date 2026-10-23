# AGENTS.md — 入口垫片

**本仓库的 AI 开发约束不在本文件。** 真实来源是 `.workbunny/`（零项目值的通用工具，可整体复制到其他项目）：

| 想知道 | 去哪 |
|---|---|
| 通用铁律（开发 / 测试 / 基准 / 注释 / 文档）+ 加载协议 + 提交前自检 | [`.workbunny/SKILLS.md`](.workbunny/SKILLS.md) |
| Zig 语言约束（0.16 基线：编译期、生命周期、ABI、构建与测试开关） | [`.workbunny/zig.md`](.workbunny/zig.md) |
| 环境、命令、仓库约束、已知环境干扰 | [`.workbunny/development.md`](.workbunny/development.md) |
| 未完成项 | [`TODO.md`](TODO.md) |
| 能力清单 | [`README.md#能力`](README.md#能力) |
| 实现决策与踩坑因果 | [`doc/special.md`](doc/special.md) |

以下三条是摘要，**正文与解释以 `SKILLS.md` 为准**（仅占位，不在此维护）：

1. **先给方案，再动手** —— 根因 / 可选方案 / 推荐与理由（含取舍与影响面），确认后实施。
2. **缺陷一经确认即修** —— 不得以「已知项」「待办」「下个版本」搁置。
3. **修复落在底层防线** —— 逐点补丁治标不治本；同类多处先找覆盖全类的公共防线。

效力：与「惯例」「顺手写法」「先跑通再说」冲突时，以 `.workbunny/SKILLS.md` 为准；确实无法遵守时，先说明冲突点与代价，不得静默绕过。
