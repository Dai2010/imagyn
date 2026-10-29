# 接口能力与降级规则

本文件说明"OpenAI / Claude 兼容"到底保证什么，以及各项失败在界面上如何呈现。

## 一句话结论

**协议兼容不等于能力兼容。** 一个地址能用 OpenAI 或 Anthropic 的请求格式通信，不代表它能出图、能收多张参考图、能给透明背景或固定分辨率。能力必须由预设配置、服务文档、用户手动覆盖和实际调用反馈共同确定；模型列表本身不足以判断。

## 能力矩阵

| 接口或功能 | 说明 | 状态 |
| --- | --- | --- |
| OpenAI Images `images/generations` | 文字生图 | 已实现 |
| OpenAI Images `images/edits` | 多参考图编辑，`image[]` 按 multipart 重复发送 | 已实现 |
| OpenAI Images SSE | 流式结果，只认 `*.completed` 事件，预览帧丢弃 | 已实现，可在兼容选项中开启 |
| OpenAI Chat Completions + 工具调用 | Agent 模式，`/chat/completions`，`parallel_tool_calls: false` | 已实现，流式与非流式 |
| OpenAI Responses + 工具调用 | Agent 模式，`/responses`，`store: false` | 已实现，流式与非流式 |
| Anthropic Messages + 工具调用 | Agent 模式，工具用 `input_schema` | 已实现，流式与非流式 |
| 视频生成 | `videos` 提交（默认 multipart）→ `videos/{id}` 轮询 → `url` 或 `/content` 下载 | 已实现；容忍 `id`/`task_id`、`status`/`task_status`、`url`/`video_url`/`data[0]`；**尚未与真实网关联调** |
| 视频模型列表 | 从视频接口的 `/models` 拉取，也可手填 | 已实现 |
| Agent 工具循环 | 20 个工具（生图、画廊列表与删除、视频、演示文稿、抓网页、提问），单轮最多 32 步 | 已实现 |
| Agent 流式显示 | 文本与思考增量逐段显示 | 已实现，三种协议都支持 |
| 演示文稿导出 | 原生 OOXML `.pptx`，文本框 / 图片 / 表格可继续编辑 | 已实现；PowerPoint / WPS 真机打开**尚未实测** |
| WebFetch `fetch_url` | 抓取一个公开 http(s) 页面的正文，默认转成 Markdown | 已实现；DeepSeek 端点改由服务端 `POST /tools/fetch` 抓取、失败回退本地；拒绝回环、私网与链路本地地址，代理模式下不抓，超长截断 |
| 提问 `ask_user` | 回合内向用户提问，回合在此结束 | 已实现 |
| 上下文压缩 | 旧回合由同一个模型总结，最近窗口原样保留；`/compact` 手动触发 | 已实现 |
| OpenAI Responses 内置 `image_generation` 工具 | 用 Responses 自带的工具生图 | **未实现**；Agent 一律调用应用的 `generate_image`，走独立 Images 接口 |
| 蒙版编辑、批量任务、云同步、本地推理 | — | **未实现**，属后续扩展 |

Claude 官方支持看图分析，但不直接生成照片或插画。因此 Anthropic 协议在本项目中承担两种角色：**图片分析**与**提示词辅助**；若要它出图，必须是该服务自己扩展的能力，并按该服务的响应格式适配。

## 单独记录的能力项

- 对话模型：图片输入、多图输入、工具调用
- 图片模型：图片输出、多参考图、编辑、输出格式、尺寸、任务查询

看图与生图是两个独立检查项。不会看图的对话模型不能被标为支持参考图分析，界面会在带上参考图时明确拒绝（`visionDisabled`），而不是静默丢弃图片。

## 接口地址的三级回退

视频、图片可以各配一套地址与密钥，留空则沿用主接口：

```
视频 → 图片 → 主接口
```

模型列表、任务提交、轮询、下载都跟着各自的地址走，密钥也按同一顺序回退。界面上"视频接口"是设置首页里独立的一栏，不折叠在图片接口里。

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
| 下载失败 | 已拿到地址但下载失败，只重试下载 |

本地任务表用的是 `submitting` / `rendering` / `complete` / `unknown` / `failed` 五个状态。已提交的任务写入本地任务表；进程被杀后重启会把仍处于"提交中"的任务标记为"未知"，交回用户判断，而不是假装成功或自动重发。

## 错误到用户文案的映射

网络层只抛错误码，界面按当前语言查表：

`invalidEndpoint`、`missingKey`、`missingImageModel`、`missingAgentModel`、`referenceLimit`、`visionDisabled`、`invalidImage`、`imageTooLarge`、`invalidProxy`、`invalidImageUrl`、`noImage`、`invalidResponse`、`unsupportedTool`、`invalidTool`、`multipleCalls`、`authError`、`rateLimit`、`serviceError`、`redirectBlocked`、`emptyPrompt`、`unknown`、`error`。

原生保存通道还会抛 `permissionDenied`（Android 9 及以下的存储权限被拒）与 `saveFailed`。`cancelled` 不显示为错误：那是用户自己按的停止。

服务端的原话（HTTP 状态码加响应体开头）作为诊断信息单独展示，不参与本地化查表；其中出现的密钥、`Authorization`、`api-key` 与 `Bearer` 片段在渲染前已被抹掉。

## 画廊与 Images 接口

生成参数、作品搜索与收藏、独立任务卡片、提交后清空输入、可选 Images SSE 结果与下载重试均已具备。Responses 内置 `image_generation` 仍未实现；Agent 的 `/responses` + 应用 `generate_image` 工具已实现。使用说明见 [image-workflow.md](image-workflow.md)。

## Agent 参数与会话模型

设置分为生图、Agent 和通用页签。支持按模型编辑系统提示词、上下文消息数量、最大输出 Tokens、Temperature 和 Top P；对话可覆盖默认值并切换 Agent / 图片 / 视频模型，历史与草稿保留。

上下文按 Token 估算：超过会话上限时，较早的回合由同一个模型总结（保留目标、约束、决定、已完成、进行中、下一步），最近的窗口原样发送，工具调用与结果不会被拆散。手动 `/compact` 生成的检查点即使关掉自动上限也仍然生效。详见 [agent-settings.md](agent-settings.md)。
