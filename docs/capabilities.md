# 接口能力与降级规则

本文件说明"OpenAI / Claude 兼容"到底保证什么。调研与设计过程见 [research.md](research.md)。

## 一句话结论

**协议兼容不等于能力兼容。** 一个地址能用 OpenAI 或 Anthropic 的请求格式通信，不代表它能出图、能收多张参考图、能给透明背景或固定分辨率。能力必须由预设配置、服务文档、用户手动覆盖和实际调用反馈共同确定；模型列表本身不足以判断。

## 能力矩阵

| 接口 | 用途 | 第一版状态 |
| --- | --- | --- |
| OpenAI Images `images/generations` | 文字生图 | 已实现 |
| OpenAI Images `images/edits` | 多参考图编辑 | 已实现，`image` 字段按 multipart 重复发送 |
| OpenAI Chat Completions + `generate_image` 工具 | Agent 对话生图 | 已实现，`parallel_tool_calls: false` |
| Anthropic Messages + `generate_image` 工具 | Agent 对话生图 | 已实现，`input_schema` 形式 |
| OpenAI Responses 生图工具 | 工具形式生图、连续修改 | 未实现 |
| 流的式事件（SSE） | 增量显示 | 未实现 |
| 蒙版编辑、批量任务、云任务查询 | — | 未实现 |

Claude 官方支持看图分析，但不直接生成照片或插画。因此 Anthropic 协议在本项目中承担两种角色：**图片分析**与**提示词辅助**；若要它出图，必须是该服务自己扩展的能力，并按该服务的响应格式适配。

## 单独记录的能力项

- 对话模型：图片输入、多图输入、工具调用
- 图片模型：图片输出、多参考图、编辑、输出格式、尺寸、任务查询

看图与生图是两个独立检查项。不会看图的对话模型不能被标为支持参考图分析，界面会在带上参考图时明确拒绝（`visionDisabled`），而不是静默丢弃图片。

## 检查的分级与顺序

从低成本到高成本：

1. 连接与模型列表（`GET /models`）
2. 最小文字回复（`checkText`）
3. 单图输入 / 多图输入
4. 工具调用
5. 最小生图、多参考图编辑

**需要付费的生成测试只由用户主动触发**，不自动扫描模型、不逐个试生成。界面区分显示"已获取模型列表 / 已通过连接检查 / 能力由预设提供 / 能力已实测 / 未知或失败"——连接检查通过时给的是"连接检查通过；模型能力尚未验证"，不是"可用"。

`/models` 失败也不等于服务不能生图：允许手填模型 ID。

## 任务状态

| 状态 | 含义 |
| --- | --- |
| 提交失败 | 请求未到达服务，可安全重试 |
| 结果未知 | 请求已发出但未拿到结果，**不自动重发**；服务端可能仍在生成，重发可能产生新任务并重复计费 |
| 生成中 | 等待结果，可取消等待 |
| 下载失败 | 已拿到图片地址但下载失败，只重试下载 |

已提交的任务写入本地任务表；进程被杀后重启会把仍处于"提交中"的任务标记为"未知"，交回用户判断，而不是假装成功或自动重发。

## 错误到用户文案的映射

网络层只抛错误码，界面按当前语言查表：`invalidEndpoint`、`missingKey`、`missingImageModel`、`missingAgentModel`、`referenceLimit`、`visionDisabled`、`invalidImage`、`imageTooLarge`、`invalidProxy`、`invalidImageUrl`、`noImage`、`invalidResponse`、`unsupportedTool`、`invalidTool`、`multipleCalls`、`authError`、`rateLimit`、`serviceError`、`emptyPrompt`。

## 待验证

以上均为设计规则，尚未用真实服务逐项验证。需要确认：实际使用的兼容服务及其响应格式、多图模型是否真的让两张参考图参与（而不是只看 HTTP 200）、四平台的代理行为、密钥存储、图片保存与切后台行为。CI 构建成功不能替代这些验收。

## 画廊与 Images 接口更新

本轮已增加生成参数、作品搜索与收藏、独立任务卡片、提交后清空输入、可选 Images SSE 结果与下载重试。实现与验证记录见 [image-workflow.md](image-workflow.md)。Responses 生图仍未实现。

## Agent 参数与会话模型

设置分为生图、Agent 和通用页签。支持按模型编辑系统提示词、上下文消息数量、最大输出 Tokens、Temperature 和 Top P；对话可覆盖默认值并切换 Agent/图片模型，历史与草稿保留。旧配置与消息向后兼容；上下文按消息条数裁剪，不进行 Token 计数或自动摘要。详见 [agent-settings.md](agent-settings.md)。
