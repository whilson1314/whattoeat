# whattoeat-server

「今晚吃啥」的自建服务端：双机同步 + LLM 代理（Key 只在服务端）+ 华为推送注册。Go 编写，SQLite 存储（modernc.org/sqlite，纯 Go 无 CGO），单一 Bearer Token 鉴权。

## 接口

| 路径 | 鉴权 | 说明 |
|---|---|---|
| `GET /health` | 无 | 健康检查，返回 LLM 白名单动作与用量 |
| `POST /sync` | Bearer | 双机同步：按 `updated_at` LWW 合并，删除走墓碑记录 |
| `POST /llm` | Bearer | LLM 代理：generate / recommend / fridge / substitute 白名单动作，按天/月限额记账，白名单外动作直接拒绝（零消耗） |
| `POST /register` | Bearer | 上报设备 push token 与推送开关，用于对方点菜时经华为 Push Kit 下发系统通知 |

## 构建与运行

```bash
go build -o wte_server .
# Linux 交叉编译
GOOS=linux GOARCH=amd64 go build -o wte_server_linux .
```

所有凭据均通过环境变量注入，源码与二进制中无任何硬编码密钥。

## 环境变量

| 变量 | 说明 |
|---|---|
| `WTE_TOKEN` | 客户端 Bearer Token（必填，未设置启动即 fatal） |
| `WTE_LISTEN` | 监听地址，默认 `:8080` |
| `WTE_DB_PATH` | SQLite 数据库路径，默认 `/opt/wte/data/wte.db` |
| `WTE_USAGE_PATH` | LLM 用量记账文件路径 |
| `WTE_LLM_API_KEY` | LLM 服务 API Key（OpenAI 兼容协议） |
| `WTE_LLM_BASE_URL` | LLM 服务地址（如 `https://api.deepseek.com`） |
| `WTE_LLM_MODEL` | 模型名 |
| `WTE_LLM_ACTIONS` | 放行的动作白名单，逗号分隔（`generate,recommend,fridge,substitute` 的子集） |
| `WTE_LLM_DAILY_LIMIT` / `WTE_LLM_MONTHLY_LIMIT` | 按天 / 按月调用次数限额 |
| `WTE_LLM_MONTHLY_TOKENS` | 按月 token 限额 |
| `WTE_HW_SA_KEY_FILE` | 华为 Push Kit v3 服务账号密钥 JSON 路径（开发者中心「服务帐号密钥」下载，含 `project_id/key_id/private_key/sub_account/token_uri`；未配置时推送关闭，不影响同步） |
| `WTE_HW_CATEGORY` | 通知自分类，默认 `MARKETING`（免申请，但静默无横幅、穿戴不展示、每设备每日限 2~5 条）；申请 IM 自分类权益后改为 `IM` |
| `WTE_HW_TEST_MESSAGE` | `true` 走测试消息通道（调试期必开，全网每日 1000 条额度）；应用上架后改 `false` 发正式消息 |
| `WTE_PUSH_API_URL` | 推送接口地址（仅测试覆盖用） |
| `WTE_XHS_BASE_URL` / `WTE_XHS_TOKEN` | 可选：本地小红书灵感检索服务的地址与令牌 |
| `WTE_XHS_DAILY_LIMIT` | 小红书搜索每日限额 |

## systemd 示例

```ini
[Unit]
Description=whattoeat server
After=network.target

[Service]
ExecStart=/opt/wte/wte_server
Environment=WTE_TOKEN=<your-token>
Environment=WTE_LLM_API_KEY=<your-llm-key>
Environment=WTE_LLM_BASE_URL=https://api.deepseek.com
Environment=WTE_LLM_MODEL=deepseek-chat
Environment=WTE_LLM_ACTIONS=generate,recommend,fridge,substitute
Environment=WTE_HW_SA_KEY_FILE=/opt/wte/data/hw_sa.json
Environment=WTE_HW_TEST_MESSAGE=true
Restart=always

[Install]
WantedBy=multi-user.target
```
