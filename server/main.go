// WhatToEat 同步服务端：夫妻点菜 App 的轻量双机同步服务
// 设计：schema-free 存储（6 张表的行以 JSON 存 payload），按 updated_at 做
// last-write-wins 合并；删除用墓碑（deleted=1）；单个 /sync 接口完成推+拉。
// 另有 /llm：LLM 代理（Key 只存服务端，端侧不接触），带日限流与结构校验。
package main

import (
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

const (
	listen = ":8080"
)

// 监听地址可用环境变量覆盖（本机 8080 常被占，测试用）
func listenAddr() string {
	if v := os.Getenv("WTE_LISTEN"); v != "" {
		return v
	}
	return listen
}

// 数据路径可用环境变量覆盖（测试用），默认生产路径
func dbPath() string {
	if v := os.Getenv("WTE_DB_PATH"); v != "" {
		return v
	}
	return "/opt/wte/data/wte.db"
}

var (
	token string
	db    *sql.DB
	mu    sync.Mutex // SQLite 单写者保护
)

// Row 客户端推送/服务端返回的行结构
type Row struct {
	Table     string `json:"table"`
	ID        string `json:"id"`
	UpdatedAt int64  `json:"updated_at"`
	Deleted   int    `json:"deleted"`
	Payload   string `json:"payload"`
}

// SyncRequest 客户端发起的同步请求
type SyncRequest struct {
	Since    int64  `json:"since"`     // 上次同步的服务端时间
	Rows     []Row  `json:"rows"`      // 客户端本地待推送的变更
	DeviceID string `json:"device_id"` // 发起同步的设备（推送时排除自己）
}

// SyncResponse 服务端响应
type SyncResponse struct {
	Rows       []Row `json:"rows"`        // since 之后服务端的全部变更
	ServerTime int64 `json:"server_time"` // 客户端下次同步的 since
	Applied    int   `json:"applied"`     // 本次服务端接受的行数
}

// ---------- LLM 代理 ----------

// llmConfig 环境变量读取的 LLM 配置
type llmConfig struct {
	BaseURL       string         // OpenAI 兼容 API 根地址
	Model         string
	APIKey        string         // 空 = 未配置，直接拒绝
	DailyLimit    int            // 单日调用上限（防突发滥用）
	MonthlyLimit  int            // 单月调用上限（付费模型预算约束）
	MonthlyTokens int64          // 单月 token 总量熔断线（输入+输出）
	Actions       map[string]bool // 动作白名单：不在名单内的功能不走 LLM
	ActionsList   []string       // 白名单顺序列表（/health 透出）
}

// llmUsage 用量账本（持久化到文件，重启不清零，按天/月滚动）
type llmUsage struct {
	Day        string `json:"date"`
	DayCount   int    `json:"count"`
	Month      string `json:"month"`
	MonthCount int    `json:"month_count"`
	TokensIn   int64  `json:"tokens_in"`
	TokensOut  int64  `json:"tokens_out"`
}

type llmReq struct {
	Action string          `json:"action"` // 白名单内动作
	Data   json.RawMessage `json:"data"`
}

type chatMessage struct {
	Role       string     `json:"role"`
	Content    string     `json:"content"`
	ToolCalls  []toolCall `json:"tool_calls,omitempty"` // assistant 发起的工具调用
	ToolCallID string     `json:"tool_call_id,omitempty"` // tool 角色回包时对应调用 id
}

// toolCall / toolDef OpenAI 兼容的 function calling 结构（DeepSeek 同协议）
type toolCall struct {
	ID       string `json:"id"`
	Type     string `json:"type"`
	Function struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"` // JSON 字符串
	} `json:"function"`
}

type toolFunction struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Parameters  map[string]any `json:"parameters"`
}

type toolDef struct {
	Type     string       `json:"type"`
	Function toolFunction `json:"function"`
}

type chatRequest struct {
	Model       string         `json:"model"`
	Messages    []chatMessage  `json:"messages"`
	Temperature float64        `json:"temperature"`
	MaxTokens   int            `json:"max_tokens"`
	Tools       []toolDef      `json:"tools,omitempty"`
	ToolChoice  map[string]any `json:"tool_choice,omitempty"` // 强制首轮调用指定工具（开关语义=必搜）
}

type chatChoice struct {
	Message chatMessage `json:"message"`
}

type chatResponse struct {
	Choices []chatChoice `json:"choices"`
	Usage   struct {
		PromptTokens     int `json:"prompt_tokens"`
		CompletionTokens int `json:"completion_tokens"`
	} `json:"usage"`
}

func main() {
	token = os.Getenv("WTE_TOKEN")
	if token == "" {
		log.Fatal("WTE_TOKEN 环境变量未设置")
	}
	if err := os.MkdirAll(filepath.Dir(dbPath()), 0755); err != nil {
		log.Fatal("创建数据目录失败: ", err)
	}
	var err error
	db, err = sql.Open("sqlite", dbPath())
	if err != nil {
		log.Fatal("打开数据库失败: ", err)
	}
	db.SetMaxOpenConns(1) // SQLite 单写者
	if _, err = db.Exec(`
		PRAGMA journal_mode=WAL;
		ALTER TABLE records ADD COLUMN server_updated_at INTEGER NOT NULL DEFAULT 0;`); err != nil {
		log.Println("迁移跳过（列已存在）")
	}
	if _, err = db.Exec(`
		PRAGMA journal_mode=WAL;
		CREATE TABLE IF NOT EXISTS records (
			table_name TEXT NOT NULL,
			id         TEXT NOT NULL,
			payload    TEXT NOT NULL,
			updated_at INTEGER NOT NULL,
			deleted    INTEGER NOT NULL DEFAULT 0,
			server_updated_at INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (table_name, id)
		);
		CREATE INDEX IF NOT EXISTS idx_records_updated ON records(table_name, server_updated_at);
		CREATE TABLE IF NOT EXISTS devices (
			device_id  TEXT PRIMARY KEY,
			push_token TEXT NOT NULL DEFAULT '',
			enabled    INTEGER NOT NULL DEFAULT 1,
			updated_at INTEGER NOT NULL DEFAULT 0
		);
	`); err != nil {
		log.Fatal("初始化表失败: ", err)
	}

	http.HandleFunc("/health", handleHealth)
	http.HandleFunc("/sync", withAuth(handleSync))
	http.HandleFunc("/llm", withAuth(handleLLM))
	http.HandleFunc("/register", withAuth(handleRegister))
	log.Println("WhatToEat 同步服务启动于 " + listenAddr())
	if err = http.ListenAndServe(listenAddr(), nil); err != nil {
		log.Fatal(err)
	}
}

// usagePath 用量账本文件（重启不清零），按天/月滚动
func usagePath() string {
	if v := os.Getenv("WTE_USAGE_PATH"); v != "" {
		return v
	}
	return "/opt/wte/data/llm_usage.json"
}

// handleHealth 健康检查：透出 LLM 可用性、白名单与用量（无敏感信息，无需鉴权）
func handleHealth(w http.ResponseWriter, r *http.Request) {
	cfg := loadLLMConfig()
	resp := map[string]any{"ok": true, "time": time.Now().UnixMilli(), "llm": cfg.APIKey != "",
		"push": hwPushEnabled(), "xhs": xhsConfigured()}
	if cfg.APIKey != "" {
		resp["model"] = cfg.Model
		resp["actions"] = cfg.ActionsList
		resp["usage"] = usageSnapshot(cfg)
	}
	writeJSON(w, http.StatusOK, resp)
}

// withAuth Bearer token 校验
func withAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+token {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
			return
		}
		next(w, r)
	}
}

// handleSync 核心接口：应用客户端变更（LWW）→ 返回 since 之后的全部服务端变更
func handleSync(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "POST only"})
		return
	}
	var req SyncRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad json"})
		return
	}
	if req.Since < 0 {
		req.Since = 0
	}

	mu.Lock()
	applied := 0
	// 计划推送事件：本次同步中「服务端首次见到的 planned MealEntry」
	var events []pushEvent
	stmt, err := db.Prepare(`
		INSERT INTO records (table_name, id, payload, updated_at, deleted, server_updated_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(table_name, id) DO UPDATE SET
			payload    = excluded.payload,
			updated_at = excluded.updated_at,
			deleted    = excluded.deleted,
			server_updated_at = excluded.server_updated_at
		WHERE excluded.updated_at >= records.updated_at
	`)
	if err != nil {
		mu.Unlock()
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	defer stmt.Close()
	for _, row := range req.Rows {
		if row.Table == "" || row.ID == "" || row.UpdatedAt <= 0 {
			continue // 坏行跳过
		}
		if ev, ok := planPushEvent(row); ok {
			events = append(events, ev)
		}
		payload := "{}"
		if len(row.Payload) > 0 {
			payload = row.Payload
		}
		res, err := stmt.Exec(row.Table, row.ID, payload, row.UpdatedAt, row.Deleted, time.Now().UnixMilli())
		if err != nil {
			log.Println("upsert err:", err)
			continue
		}
		if n, _ := res.RowsAffected(); n > 0 {
			applied++
		}
	}

	// 拉取 since 之后的全部变更
	rows, err := db.Query(
		`SELECT table_name, id, payload, updated_at, deleted
		 FROM records WHERE server_updated_at > ? ORDER BY server_updated_at ASC`, req.Since)
	if err != nil {
		mu.Unlock()
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	out := make([]Row, 0)
	for rows.Next() {
		var t, id, payload string
		var ua int64
		var del int
		if err := rows.Scan(&t, &id, &payload, &ua, &del); err == nil {
			out = append(out, Row{
				Table: t, ID: id, UpdatedAt: ua, Deleted: del,
				Payload: payload,
			})
		}
	}
	rows.Close()
	mu.Unlock()

	// 锁外异步推送（失败不影响同步响应）
	if len(events) > 0 {
		go dispatchPlanPush(req.DeviceID, events)
	}

	serverTime := time.Now().UnixMilli()
	writeJSON(w, http.StatusOK, SyncResponse{
		Rows: out, ServerTime: serverTime, Applied: applied,
	})
}

// ==================== 计划推送（华为 Push Kit） ====================
// 对方把菜加入计划（新增 planned MealEntry）时，通过华为推送把通知发到另一台
// 设备——App 未启动也能收到。走 v3 场景化消息接口：URL 用项目 ID，鉴权用服务
// 账号密钥直接签 JWT（PS256，不走 OAuth），报文 payload/target/pushOptions。
// 密钥文件未配置时仅记日志跳过，不影响同步主链路。

// hwServiceAccount AGC「项目设置→常规→服务帐号密钥」下载的 JSON（脱敏入库外）
type hwServiceAccount struct {
	ProjectID  string `json:"project_id"`
	KeyID      string `json:"key_id"`
	PrivateKey string `json:"private_key"`
	SubAccount string `json:"sub_account"`
	TokenURI   string `json:"token_uri"`
}

// hwPush 服务账号与 JWT 缓存（有效期 1h，提前 5 分钟续签）
type hwPush struct {
	mu       sync.Mutex
	sa       *hwServiceAccount
	jwt      string
	jwtExp   time.Time
	category string // 通知自分类：MARKETING 免申请；IM 等需在 AGC 申请自分类权益
	testMsg  bool   // debug/未上架应用只能发测试消息，上架后置 false
}

var pushCfg = &hwPush{}

func hwPushEnabled() bool {
	return pushCfg.sa != nil
}

func init() {
	// 服务账号密钥文件（json，字段 project_id/key_id/private_key/sub_account/token_uri）
	if v := os.Getenv("WTE_HW_SA_KEY_FILE"); v != "" {
		buf, err := os.ReadFile(v)
		if err != nil {
			log.Printf("push: 读服务账号密钥失败 %s: %v", v, err)
		} else {
			var sa hwServiceAccount
			if err := json.Unmarshal(buf, &sa); err != nil || sa.PrivateKey == "" {
				log.Printf("push: 服务账号密钥解析失败（缺 private_key?）")
			} else {
				pushCfg.sa = &sa
			}
		}
	}
	pushCfg.category = "MARKETING"
	if v := os.Getenv("WTE_HW_CATEGORY"); v != "" {
		pushCfg.category = v
	}
	pushCfg.testMsg = os.Getenv("WTE_HW_TEST_MESSAGE") == "true"
	// 测试可覆盖 API 地址（默认华为线上环境）
	if v := os.Getenv("WTE_PUSH_API_URL"); v != "" {
		hwAPIURL = v
	}
}

var hwAPIURL = "https://push-api.cloud.huawei.com"

// pushEvent 一次计划新增推送的内容
type pushEvent struct {
	title string
	body  string
}

// planPushEvent 判断一行是否值得推送：MealEntry、非删除、服务端首次见到、
// status=planned、行时间在 10 分钟内（服务端清库/换机全量重推时不轰炸）。
// 必须在持有 mu 时调用（要查 records 表）。
func planPushEvent(row Row) (pushEvent, bool) {
	if row.Table != "MealEntry" || row.Deleted != 0 {
		return pushEvent{}, false
	}
	if time.Since(time.UnixMilli(row.UpdatedAt)) > 10*time.Minute {
		return pushEvent{}, false
	}
	var cnt int
	if err := db.QueryRow(`SELECT COUNT(*) FROM records WHERE table_name=? AND id=?`,
		row.Table, row.ID).Scan(&cnt); err != nil || cnt > 0 {
		return pushEvent{}, false // 服务端已见过该行（更新/重推），不算新增
	}
	var p struct {
		Status   string `json:"status"`
		DishName string `json:"dishName"`
		PickedBy string `json:"pickedBy"`
		Date     string `json:"date"`
		MealType string `json:"mealType"`
	}
	if err := json.Unmarshal([]byte(row.Payload), &p); err != nil {
		return pushEvent{}, false
	}
	if p.Status != "planned" || strings.TrimSpace(p.DishName) == "" {
		return pushEvent{}, false
	}
	who := strings.TrimSpace(p.PickedBy)
	title := "有人点菜啦 🍜"
	if who != "" {
		title = who + " 点菜啦 🍜"
	}
	body := "「" + p.DishName + "」已加入" + weekdayCn(p.Date) + "的" + mealTypeCn(p.MealType) + "计划"
	return pushEvent{title: title, body: body}, true
}

// weekdayCn date(yyyy-MM-dd) → 周X，解析失败返回空串
func weekdayCn(dateStr string) string {
	t, err := time.Parse("2006-01-02", dateStr)
	if err != nil {
		return ""
	}
	return []string{"周日", "周一", "周二", "周三", "周四", "周五", "周六"}[int(t.Weekday())]
}

// mealTypeCn lunch/dinner → 中文
func mealTypeCn(t string) string {
	if t == "lunch" {
		return "午餐"
	}
	return "晚餐"
}

// registerReq 设备推送注册请求
type registerReq struct {
	DeviceID  string `json:"device_id"`
	PushToken string `json:"push_token"`
	Enabled   *bool  `json:"enabled"` // 缺省视为 true
}

// handleRegister 设备注册推送 token（App 每次启动上报，开关切换也调）
func handleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "POST only"})
		return
	}
	var req registerReq
	if err := json.NewDecoder(io.LimitReader(r.Body, 4<<10)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad json"})
		return
	}
	req.DeviceID = strings.TrimSpace(req.DeviceID)
	if req.DeviceID == "" || len(req.DeviceID) > 64 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad device_id"})
		return
	}
	enabled := 1
	if req.Enabled != nil && !*req.Enabled {
		enabled = 0
	}
	token := strings.TrimSpace(req.PushToken)
	if len(token) > 256 {
		token = ""
	}
	mu.Lock()
	defer mu.Unlock()
	// 空 token 不覆盖已登记的有效 token（只同步 enabled 开关）
	_, err := db.Exec(`
		INSERT INTO devices (device_id, push_token, enabled, updated_at) VALUES (?, ?, ?, ?)
		ON CONFLICT(device_id) DO UPDATE SET
			push_token = CASE WHEN excluded.push_token = '' THEN devices.push_token ELSE excluded.push_token END,
			enabled = excluded.enabled,
			updated_at = excluded.updated_at
	`, req.DeviceID, token, enabled, time.Now().UnixMilli())
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// dispatchPlanPush 把事件推给除发起设备外的所有启用设备（goroutine 中执行）
func dispatchPlanPush(excludeDeviceID string, events []pushEvent) {
	if !hwPushEnabled() {
		log.Printf("push skip: 华为推送凭据未配置（WTE_HW_APP_ID/WTE_HW_APP_SECRET），%d 条事件丢弃", len(events))
		return
	}
	mu.Lock()
	rows, err := db.Query(`SELECT device_id, push_token FROM devices WHERE enabled = 1 AND push_token != ''`)
	type target struct{ id, token string }
	targets := make([]target, 0, 4)
	if err == nil {
		for rows.Next() {
			var id, tk string
			if err := rows.Scan(&id, &tk); err == nil && id != excludeDeviceID {
				targets = append(targets, target{id: id, token: tk})
			}
		}
	}
	rows.Close()
	mu.Unlock()
	if err != nil {
		log.Println("push query err:", err)
		return
	}
	for _, ev := range events {
		for _, t := range targets {
			if err := sendHwPush(t.token, ev.title, ev.body); err != nil {
				log.Printf("push to %s failed: %v", t.id, err)
			} else {
				log.Printf("push to %s ok: %s | %s", t.id, ev.title, ev.body)
			}
		}
	}
}

// hwPushJWT 用服务账号私钥签 v3 接口的 Bearer JWT（PS256，有效期 1h，提前 5 分钟续签）。
// 报文结构与官方 server demo 一致：header{alg,typ,kid} + payload{iss=sub_account, aud=token_uri, iat, exp}。
func hwPushJWT() (string, error) {
	pushCfg.mu.Lock()
	defer pushCfg.mu.Unlock()
	if pushCfg.jwt != "" && time.Now().Before(pushCfg.jwtExp) {
		return pushCfg.jwt, nil
	}
	sa := pushCfg.sa
	block, _ := pem.Decode([]byte(sa.PrivateKey))
	if block == nil {
		return "", fmt.Errorf("service account key pem decode failed")
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return "", fmt.Errorf("parse private key: %w", err)
	}
	rsaKey, ok := key.(*rsa.PrivateKey)
	if !ok {
		return "", fmt.Errorf("private key is not RSA")
	}
	now := time.Now()
	hb, _ := json.Marshal(map[string]any{"alg": "PS256", "typ": "JWT", "kid": sa.KeyID})
	pb, _ := json.Marshal(map[string]any{
		"iss": sa.SubAccount,
		"aud": sa.TokenURI,
		"iat": now.Unix(),
		"exp": now.Add(time.Hour).Unix(),
	})
	b64 := func(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }
	signingInput := b64(hb) + "." + b64(pb)
	h := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPSS(rand.Reader, rsaKey, crypto.SHA256, h[:], &rsa.PSSOptions{SaltLength: rsa.PSSSaltLengthEqualsHash})
	if err != nil {
		return "", fmt.Errorf("sign jwt: %w", err)
	}
	pushCfg.jwt = signingInput + "." + b64(sig)
	pushCfg.jwtExp = now.Add(55 * time.Minute)
	return pushCfg.jwt, nil
}

// sendHwPush 调华为 Push v3 REST API 发一条通知消息（actionType=0 点击打开应用首页）
func sendHwPush(deviceToken, title, body string) error {
	jwt, err := hwPushJWT()
	if err != nil {
		return fmt.Errorf("get jwt: %w", err)
	}
	msg := map[string]any{
		"payload": map[string]any{
			"notification": map[string]any{
				"category":    pushCfg.category, // v3 必填：通知自分类
				"title":       title,
				"body":        body,
				"clickAction": map[string]any{"actionType": 0}, // 0=打开应用首页
				"badge":       map[string]any{"addNum": 1},     // 图标角标累加；端侧回前台清零
			},
		},
		"target":      map[string]any{"token": []string{deviceToken}},
		"pushOptions": map[string]any{"testMessage": pushCfg.testMsg}, // debug/未上架应用只能发测试消息
	}
	buf, _ := json.Marshal(msg)
	// v3 URL 用项目 ID（SA 文件缺 project_id 时回退环境变量）
	pathID := pushCfg.sa.ProjectID
	if pathID == "" {
		pathID = os.Getenv("WTE_HW_PROJECT_ID")
	}
	req, err := http.NewRequest("POST", hwAPIURL+"/v3/"+pathID+"/messages:send", bytes.NewReader(buf))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json; charset=UTF-8")
	req.Header.Set("Authorization", "Bearer "+jwt)
	req.Header.Set("push-type", "0") // 0=通知消息（ALERT）
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	var out struct {
		Code string `json:"code"`
		Msg  string `json:"msg"`
	}
	_ = json.NewDecoder(io.LimitReader(resp.Body, 16<<10)).Decode(&out)
	if out.Code == "80000000" {
		return nil
	}
	if out.Code == "80300007" { // token 失效：清理注册行，等设备下次启动重新登记。
		// 30 分钟内注册的新 token 不删：服务开通/权益传播期间云端会误报失效（2026-11-08 实测连删三次新 token）
		mu.Lock()
		_, _ = db.Exec(`DELETE FROM devices WHERE push_token = ? AND updated_at < ?`,
			deviceToken, time.Now().Add(-30*time.Minute).UnixMilli())
		mu.Unlock()
		return fmt.Errorf("token invalid (%s %s)", out.Code, out.Msg)
	}
	return fmt.Errorf("push api %s: %s %s", resp.Status, out.Code, out.Msg)
}

// ==================== /llm：LLM 代理 ====================

func loadLLMConfig() llmConfig {
	cfg := llmConfig{
		BaseURL:       strings.TrimRight(os.Getenv("WTE_LLM_BASE_URL"), "/"),
		Model:         os.Getenv("WTE_LLM_MODEL"),
		APIKey:        os.Getenv("WTE_LLM_API_KEY"),
		DailyLimit:    20,
		MonthlyLimit:  30,
		MonthlyTokens: 150000,
		Actions:       map[string]bool{},
	}
	if cfg.BaseURL == "" {
		cfg.BaseURL = "https://api.deepseek.com" // DeepSeek（OpenAI 兼容）
	}
	if cfg.Model == "" {
		cfg.Model = "deepseek-chat"
	}
	if v := os.Getenv("WTE_LLM_DAILY_LIMIT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			cfg.DailyLimit = n
		}
	}
	if v := os.Getenv("WTE_LLM_MONTHLY_LIMIT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			cfg.MonthlyLimit = n
		}
	}
	if v := os.Getenv("WTE_LLM_MONTHLY_TOKENS"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			cfg.MonthlyTokens = n
		}
	}
	// 动作白名单：默认全部四个动作走 LLM（2026-11-06 用户确认放开）。
	// 若需收紧（省 token）可用 WTE_LLM_ACTIONS 覆盖，名单外动作端侧自动降级本地逻辑。
	actions := os.Getenv("WTE_LLM_ACTIONS")
	if actions == "" {
		actions = "generate,substitute,recommend,fridge"
	}
	for _, a := range strings.Split(actions, ",") {
		a = strings.TrimSpace(a)
		if a == "" {
			continue
		}
		cfg.Actions[a] = true
		cfg.ActionsList = append(cfg.ActionsList, a)
	}
	return cfg
}

// loadUsage 读取用量账本（调用方需持锁）
func loadUsage() llmUsage {
	raw, _ := os.ReadFile(usagePath())
	var u llmUsage
	json.Unmarshal(raw, &u)
	return u
}

// saveUsage 持久化账本（调用方需持锁）
func saveUsage(u llmUsage) {
	buf, _ := json.Marshal(u)
	_ = os.WriteFile(usagePath(), buf, 0644)
}

// rollUsage 按当前日/月滚动归零（调用方需持锁）
func rollUsage(u *llmUsage) {
	today := time.Now().Format("2006-01-02")
	month := time.Now().Format("2006-01")
	if u.Day != today {
		u.Day = today
		u.DayCount = 0
	}
	if u.Month != month {
		u.Month = month
		u.MonthCount = 0
		u.TokensIn = 0
		u.TokensOut = 0
	}
}

// preCharge 单次调用前：锁定校验日/月调用与月 token 预算，通过则预扣计数。
// 返回 (拒绝原因, 扣后月调用数)。预扣失败不退回，防重试滥用。
func preCharge(cfg llmConfig) (string, int) {
	mu.Lock()
	defer mu.Unlock()
	u := loadUsage()
	rollUsage(&u)
	if u.DayCount >= cfg.DailyLimit {
		return "今日 AI 调用已达上限（" + strconv.Itoa(cfg.DailyLimit) + " 次），明天再来", u.MonthCount
	}
	if u.MonthCount >= cfg.MonthlyLimit {
		return "本月 AI 调用已达上限（" + strconv.Itoa(cfg.MonthlyLimit) + " 次），下月 1 日恢复", u.MonthCount
	}
	if u.TokensIn+u.TokensOut >= cfg.MonthlyTokens {
		return "本月 AI token 额度已用完（上限 " + strconv.FormatInt(cfg.MonthlyTokens, 10) + " tokens），下月 1 日恢复", u.MonthCount
	}
	u.DayCount++
	u.MonthCount++
	saveUsage(u)
	return "", u.MonthCount
}

// commitTokens 单次调用成功后：锁定重读账本并累计 token（避免读改写竞争覆盖计数）
func commitTokens(tokensIn, tokensOut int64) {
	mu.Lock()
	defer mu.Unlock()
	u := loadUsage()
	rollUsage(&u)
	u.TokensIn += tokensIn
	u.TokensOut += tokensOut
	saveUsage(u)
}

// usageSnapshot 只读快照（展示用，不落盘）
func usageSnapshot(cfg llmConfig) map[string]any {
	mu.Lock()
	defer mu.Unlock()
	u := loadUsage()
	rollUsage(&u)
	return map[string]any{
		"day_count":    u.DayCount,
		"day_limit":    cfg.DailyLimit,
		"month_count":  u.MonthCount,
		"month_limit":  cfg.MonthlyLimit,
		"tokens_in":    u.TokensIn,
		"tokens_out":   u.TokensOut,
		"tokens_limit": cfg.MonthlyTokens,
	}
}

// handleLLM 端侧 AI 请求统一入口：{action, data} → 组装 prompt → 调 OpenAI 兼容 API → 校验 → 返回
func handleLLM(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "POST only"})
		return
	}
	cfg := loadLLMConfig()
	if cfg.APIKey == "" {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "LLM 未配置（服务器缺少 WTE_LLM_API_KEY）", "code": "no_key"})
		return
	}
	var req llmReq
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad json"})
		return
	}

	// 第 0 层限制：动作白名单——名单外的功能（问AI助手/清冰箱等）一律不走 LLM，
	// 直接拒绝且不消耗任何额度，端侧自动降级本地逻辑。
	if !cfg.Actions[req.Action] {
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":    false,
			"error": "该功能未开放 AI（当前仅开放：AI 加菜、食材替换），已自动使用本地逻辑",
			"code":  "action_disabled",
		})
		return
	}

	var sysPrompt, userPrompt string
	var maxTokens int
	webMode := false // recommend 且端侧 opt-in 且服务端已配置 xiaohongshu-mcp
	switch req.Action {
	case "generate":
		var d struct {
			Name string `json:"name"`
			Hint string `json:"hint"`
		}
		if err := json.Unmarshal(req.Data, &d); err != nil || strings.TrimSpace(d.Name) == "" {
			writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "缺少菜名"})
			return
		}
		sysPrompt = recipeSchemaPrompt(false)
		userPrompt = "请为这道菜生成完整菜谱。\n菜名：" + truncate(strings.TrimSpace(d.Name), 60) +
			truncateOpt("\n补充描述：", d.Hint, 200)
		maxTokens = 900
	case "fridge":
		var d struct {
			Ingredients []string `json:"ingredients"`
			Hint        string   `json:"hint"`
		}
		if err := json.Unmarshal(req.Data, &d); err != nil || len(d.Ingredients) == 0 {
			writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "缺少食材"})
			return
		}
		sysPrompt = recipeSchemaPrompt(true)
		userPrompt = "请只用这些食材设计一道菜（可默认家里有油盐酱醋等基础调味料，其他食材不得额外添加超过 2 样常规辅材如葱蒜）。\n现有食材：" +
			truncate(strings.Join(d.Ingredients, "、"), 300) +
			truncateOpt("\n补充要求：", d.Hint, 100)
		maxTokens = 900
	case "recommend":
		var d struct {
			Utterance string   `json:"utterance"`
			Mood      string   `json:"mood"`
			Recent    []string `json:"recent"`
			Planned   []string `json:"planned"`
			Web       bool     `json:"web"` // 端侧 opt-in：本次允许查小红书
			Recipes   []map[string]any `json:"recipes"`
		}
		if err := json.Unmarshal(req.Data, &d); err != nil {
			writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "bad data"})
			return
		}
		lib := make([]string, 0, len(d.Recipes))
		for _, r2 := range d.Recipes {
			lib = append(lib, fmt.Sprintf(`{"id":"%v","name":"%v","cuisine":"%v","taste":"%v","category":"%v","isQuick":%v}`,
				r2["id"], r2["name"], r2["cuisine"], r2["taste"], r2["category"], r2["isQuick"]))
		}
		sysPrompt = "你是家庭点菜助手「AI 助手」。根据用户描述从给定的菜谱库中挑选 3 道菜。" +
			"只能从菜谱库中已有的 id 里选，绝不编造不存在的菜；避免与近7天吃过的重复。" +
			"输出严格 JSON（无任何多余文字）：{\"picks\":[{\"recipeId\":\"id\",\"reason\":\"15字内理由\"}],\"note\":\"20字内的一句回应\"}"
		userPrompt = "用户说：" + truncate(strings.TrimSpace(d.Utterance), 500)
		if d.Mood != "" {
			userPrompt += "\n当前心情：" + d.Mood
		}
		if len(d.Recent) > 0 {
			userPrompt += "\n近7天已吃过（避免推荐）：" + strings.Join(d.Recent, "、")
		}
		if len(d.Planned) > 0 {
			userPrompt += "\n今天已安排：" + strings.Join(d.Planned, "、")
		}
		userPrompt += "\n菜谱库：" + truncate("["+strings.Join(lib, ",")+"]", 40000)
		maxTokens = 500
		if d.Web && xhsConfigured() {
			webMode = true
			// 开关语义 = 用户明确要求这一问结合小红书：必须先搜索再回答，
			// 不能因为「库里已有匹配」就跳过（否则模糊需求如"想吃清淡的"永远不触发搜索）
			sysPrompt = "你是家庭点菜助手「AI 助手」，本次用户已打开「查小红书」开关：你必须先调用 search_xhs_notes 搜索一次再回答。" +
				"关键词要从用户需求提炼成具体可搜的短语（如「清淡 晚餐」「减脂餐 简单」「低脂 家常菜」），不要把用户原话整句直接当关键词。" +
				"需要某条笔记的具体做法细节时用 get_note_detail（本次最多一次）。" +
				"回答时：picks 从菜谱库选（只能选库内 id，可为空数组，避免与近7天吃过重复）；" +
				"inspirations 从搜索结果挑最贴合用户需求的 2-3 条，ref 必须是搜索结果给出的序号，" +
				"summary 用自己的话提炼（15字内），绝不照抄原文长句。" +
				"dish 填该笔记里值得做的具体菜名（8字内）：单菜笔记给菜名本身；合集类笔记（标题含合集/一周/不重样/多种等）" +
				"优先用 get_note_detail 看正文后挑一道最贴合用户需求的菜，没看正文的合集留空 dish。" +
				"inspirations 不要推荐菜谱库里已经有的菜（同菜异名也算重复，如库里已有可乐鸡翅就别选讲解可乐鸡翅的笔记、" +
				"西红柿炒鸡蛋≈番茄炒蛋）；优先挑库外的新菜或明显不同的新做法。" +
				"工具失败或没有结果时只给库内推荐，不要向用户提及工具。" +
				"输出严格 JSON（无任何多余文字）：{\"picks\":[{\"recipeId\":\"id\",\"reason\":\"15字内理由\"}]," +
				"\"inspirations\":[{\"ref\":1,\"summary\":\"15字内\",\"dish\":\"蜜汁鸡翅\"}],\"note\":\"20字内的一句回应\"}"
			userPrompt += "\n本次已开启小红书检索，必须先搜索再回答。"
			maxTokens = 700
		}
	case "substitute":
		var d struct {
			Ingredient string `json:"ingredient"`
			Dish       string `json:"dish"`
		}
		if err := json.Unmarshal(req.Data, &d); err != nil || strings.TrimSpace(d.Ingredient) == "" {
			writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "缺少食材"})
			return
		}
		sysPrompt = "你是厨房顾问。为做菜时缺少的食材给出 3 个中国家庭厨房常见的替代品（每种不超过8字）。" +
			"输出严格 JSON：{\"substitutes\":[\"替代品1\",\"替代品2\",\"替代品3\"],\"note\":\"简短说明(20字内)\"}"
		userPrompt = "缺少的食材：" + truncate(strings.TrimSpace(d.Ingredient), 30)
		if d.Dish != "" {
			userPrompt += "（要做：" + truncate(d.Dish, 30) + "）"
		}
		maxTokens = 200
	default:
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "未知 action"})
		return
	}

	// 限额三层：日调用 → 月调用 → 月 token 预算（持久账本，预扣+成功后记 token）
	deny, monthUsed := preCharge(cfg)
	if deny != "" {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": deny, "code": "rate_limited"})
		return
	}

	// web 模式：LLM 可调用小红书搜索/详情工具；ref→笔记映射供返回校验用
	webNotes := map[int]xhsNote{}
	var content string
	var tokensIn, tokensOut int64
	var err error
	if webMode {
		nextRef := 1
		tools := []toolDef{
			{Type: "function", Function: toolFunction{
				Name:        "search_xhs_notes",
				Description: "按关键词搜索小红书笔记，返回最多 8 条（ref 序号、标题、作者、点赞数）。用于找做法灵感或了解流行吃法。",
				Parameters: map[string]any{
					"type": "object",
					"properties": map[string]any{
						"keyword": map[string]any{"type": "string", "description": "搜索关键词，如：空气炸锅 鸡翅"},
					},
					"required": []string{"keyword"},
				},
			}},
			{Type: "function", Function: toolFunction{
				Name:        "get_note_detail",
				Description: "查看某条小红书笔记的正文（ref 为搜索结果给出的序号）。本次对话最多调用一次。",
				Parameters: map[string]any{
					"type": "object",
					"properties": map[string]any{
						"ref": map[string]any{"type": "integer", "description": "搜索结果中的 ref 序号"},
					},
					"required": []string{"ref"},
				},
			}},
		}
		executor := func(name, args string) (string, error) {
			switch name {
			case "search_xhs_notes":
				var a struct {
					Keyword string `json:"keyword"`
				}
				if err := json.Unmarshal([]byte(args), &a); err != nil {
					return "", err
				}
				kw := truncate(strings.TrimSpace(a.Keyword), 30)
				if kw == "" {
					return "缺少搜索关键词", nil
				}
				notes, serr := xhsSearchRaw(kw)
				if serr != nil {
					return "小红书查询失败：" + serr.Error(), nil
				}
				if len(notes) == 0 {
					return "没有搜到相关笔记，可换个关键词", nil
				}
				log.Printf("xhs search: %q -> %d notes", kw, len(notes))
				items := make([]string, 0, len(notes))
				for _, n := range notes {
					ref := nextRef
					nextRef++
					webNotes[ref] = n
					b, _ := json.Marshal(map[string]any{
						"ref": ref, "title": n.Title, "author": n.Author, "likes": n.Likes,
					})
					items = append(items, string(b))
				}
				return "[" + strings.Join(items, ",") + "]", nil
			case "get_note_detail":
				var a struct {
					Ref int `json:"ref"`
				}
				if err := json.Unmarshal([]byte(args), &a); err != nil {
					return "", err
				}
				n, ok := webNotes[a.Ref]
				if !ok {
					return "ref 无效，请先用 search_xhs_notes 搜索", nil
				}
				text, derr := xhsNoteDetail(n.FeedID, n.XsecToken)
				if derr != nil {
					return "笔记详情获取失败：" + derr.Error(), nil
				}
				log.Printf("xhs detail: feed %s", n.FeedID)
				return "【" + n.Title + "】" + text, nil
			}
			return "未知工具", nil
		}
		content, tokensIn, tokensOut, err = callChatWithTools(cfg, sysPrompt, userPrompt, maxTokens,
			tools, executor, 3, 2, "search_xhs_notes")
	} else {
		content, tokensIn, tokensOut, err = callChat(cfg, sysPrompt, userPrompt, maxTokens)
	}
	if err != nil {
		log.Printf("llm %s fail: %s (web=%v)", req.Action, err.Error(), webMode)
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "AI 调用失败：" + err.Error(), "code": "upstream"})
		return
	}
	// token 记账（成功才记；多轮工具循环的 usage 已累计，一次入账）
	commitTokens(tokensIn, tokensOut)
	obj, perr := extractJSONObject(content)
	if perr != nil {
		log.Printf("llm %s parse fail: %q", req.Action, truncate(content, 200))
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "AI 返回无法解析", "code": "parse"})
		return
	}

	// 防幻觉校验 + 字段清洗
	var data any
	switch req.Action {
	case "generate", "fridge":
		cleaned, verr := cleanRecipe(obj, req.Action == "fridge")
		if verr != "" {
			writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": verr, "code": "validate"})
			return
		}
		data = cleaned
	case "recommend":
		// picks 的 id 必须在传入菜谱库内
		var d struct {
			Recipes []map[string]any `json:"recipes"`
		}
		_ = json.Unmarshal(req.Data, &d)
		valid := map[string]bool{}
		for _, r2 := range d.Recipes {
			valid[fmt.Sprintf("%v", r2["id"])] = true
		}
		picks, _ := obj["picks"].([]any)
		outPicks := make([]map[string]any, 0, 3)
		seen := map[string]bool{}
		for _, p := range picks {
			pm, _ := p.(map[string]any)
			if pm == nil {
				continue
			}
			id := fmt.Sprintf("%v", pm["recipeId"])
			if !valid[id] || seen[id] {
				continue
			}
			seen[id] = true
			reason, _ := pm["reason"].(string)
			if len([]rune(reason)) > 30 {
				reason = string([]rune(reason)[:30])
			}
			outPicks = append(outPicks, map[string]any{"recipeId": id, "reason": reason})
			if len(outPicks) >= 3 {
				break
			}
		}
		// inspirations：ref 必须命中本次工具返回的笔记表（硬映射，防编造链接）
		outInsp := make([]map[string]any, 0, 3)
		if webMode {
			// 库内同菜过滤：dish 与自家菜谱本质相同就丢掉（确定性兜底，语义判断在提示词层）
			libNames := make([]string, 0, len(d.Recipes))
			for _, r2 := range d.Recipes {
				if n, ok := r2["name"].(string); ok {
					libNames = append(libNames, n)
				}
			}
			isDup := func(dish string) bool {
				dr := []rune(dish)
				for _, ln := range libNames {
					if dish == ln {
						return true
					}
					lr := []rune(ln)
					short := dr
					if len(lr) < len(short) {
						short = lr
					}
					if len(short) >= 3 && (strings.Contains(dish, ln) || strings.Contains(ln, dish)) {
						return true
					}
				}
				return false
			}
			insp, _ := obj["inspirations"].([]any)
			seenRef := map[int]bool{}
			for _, iv := range insp {
				im, _ := iv.(map[string]any)
				if im == nil {
					continue
				}
				ref := 0
				switch v := im["ref"].(type) {
				case float64:
					ref = int(v)
				case string:
					ref, _ = strconv.Atoi(strings.TrimSpace(v))
				}
				n, ok := webNotes[ref]
				if !ok || seenRef[ref] {
					continue
				}
				seenRef[ref] = true
				summary, _ := im["summary"].(string)
				out := map[string]any{
					"title": n.Title, "author": n.Author, "likes": n.Likes,
					"url":     xhsNoteURL(n),
					"summary": truncate(summary, 40),
				}
				// dish：合集类笔记里 LLM 挑出的具体菜名（拿不到时客户端降级为看原文挑菜）
				dish, _ := im["dish"].(string)
				dish = truncate(strings.TrimSpace(dish), 16)
				// dish 与库内已有菜重复：整条丢弃（灵感只补库外增量）
				if dish != "" && isDup(dish) {
					continue
				}
				if dish != "" {
					out["dish"] = dish
				}
				outInsp = append(outInsp, out)
				if len(outInsp) >= 3 {
					break
				}
			}
		}
		if len(outPicks) == 0 && len(outInsp) == 0 {
			log.Printf("llm recommend validate fail: picks=%d raw=%q", len(picks), truncate(fmt.Sprint(obj["picks"]), 200))
			writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "AI 没有给出有效的推荐", "code": "validate"})
			return
		}
		note, _ := obj["note"].(string)
		if len([]rune(note)) > 40 {
			note = string([]rune(note)[:40])
		}
		rd := map[string]any{"picks": outPicks, "note": note}
		if len(outInsp) > 0 {
			rd["inspirations"] = outInsp
		}
		data = rd
	case "substitute":
		subs, _ := obj["substitutes"].([]any)
		out := make([]string, 0, 3)
		for _, s := range subs {
			ss, _ := s.(string)
			if strings.TrimSpace(ss) != "" {
				out = append(out, strings.TrimSpace(ss))
			}
			if len(out) >= 3 {
				break
			}
		}
		if len(out) == 0 {
			writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "AI 没给出替换建议", "code": "validate"})
			return
		}
		note, _ := obj["note"].(string)
		data = map[string]any{"substitutes": out, "note": note}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"ok":          true,
		"data":        data,
		"used_month":  monthUsed,
		"month_limit": cfg.MonthlyLimit,
		"tokens_in":   tokensIn,
		"tokens_out":  tokensOut,
		"model":       cfg.Model,
	})
}

// recipeSchemaPrompt 菜谱 JSON 结构约束（generate/fridge 共用）
func recipeSchemaPrompt(isFridge bool) string {
	intro := "你是中餐菜谱编辑。根据菜名生成一道家常菜的完整信息"
	if isFridge {
		intro = "你是节俭的家庭厨师。根据现有食材设计一道能做的菜"
	}
	return intro + "。输出严格 JSON，不要 markdown 代码块和任何多余文字，字段如下：\n" +
		`{"name":"菜名","emoji":"一个食物emoji","cuisine":"菜系(只能: 家常菜/川菜/粤菜/湘菜/东北菜/西北菜/江浙菜/西餐/日料/其他)",` +
		`"taste":"口味(只能: 咸鲜/辣/酸辣/香辣/清淡/酸甜/甜/鱼香)",` +
		`"category":"类型(只能: 荤菜/素菜/水产/汤粥/主食/早餐/甜品/饮品/酱料/半成品)",` +
		`"type":"荤或素或汤或主食(素菜→素,汤粥→汤,主食/早餐→主食,其余→荤)",` +
		`"isQuick":true或false(30分钟内且简单),"durationMin":总分钟整数,"difficulty":1到5整数,` +
		`"calories":每份大卡整数(未知0),"protein":每份蛋白质克整数(未知0),"fat":每份脂肪克整数(未知0),"carbs":每份碳水克整数(未知0),` +
		`"ingredients":[{"name":"食材名(2-6字)","amount":"用量如 200g/2个/适量","category":"蔬菜/肉类/水产/蛋奶豆/主食/调味/其他"}],` +
		`"steps":["第1步","第2步"(4到8步，每步不超过50字)],"tips":["小贴士"(0到3条)]}`
}

// cleanRecipe 菜谱结构清洗与归一化（防幻觉第 4 层：字段校验）
func cleanRecipe(obj map[string]any, isFridge bool) (map[string]any, string) {
	getStr := func(m map[string]any, k string) string {
		if v, ok := m[k].(string); ok {
			return strings.TrimSpace(v)
		}
		return ""
	}
	getInt := func(m map[string]any, k string) int {
		switch v := m[k].(type) {
		case float64:
			return int(v)
		case string:
			n, _ := strconv.Atoi(strings.TrimSpace(v))
			return n
		}
		return 0
	}
	name := getStr(obj, "name")
	if name == "" {
		return nil, "AI 返回缺少菜名"
	}
	if len([]rune(name)) > 30 {
		name = string([]rune(name)[:30])
	}
	cuisines := []string{"家常菜", "川菜", "粤菜", "湘菜", "东北菜", "西北菜", "江浙菜", "西餐", "日料", "其他"}
	cuisine := pickAllowed(getStr(obj, "cuisine"), cuisines, "家常菜")
	tastes := []string{"咸鲜", "辣", "酸辣", "香辣", "清淡", "酸甜", "甜", "鱼香"}
	taste := pickAllowed(getStr(obj, "taste"), tastes, "咸鲜")
	cats := []string{"荤菜", "素菜", "水产", "汤粥", "主食", "早餐", "甜品", "饮品", "酱料", "半成品"}
	category := pickAllowed(getStr(obj, "category"), cats, "荤菜")
	typ := getStr(obj, "type")
	switch category {
	case "素菜":
		typ = "素"
	case "汤粥":
		typ = "汤"
	case "主食", "早餐":
		typ = "主食"
	case "水产":
		typ = "荤"
	default:
		if typ != "荤" && typ != "素" && typ != "汤" && typ != "主食" {
			typ = "荤"
		}
	}
	ings, _ := obj["ingredients"].([]any)
	outIngs := make([]map[string]any, 0, len(ings))
	ingCats := []string{"蔬菜", "肉类", "水产", "蛋奶豆", "主食", "调味", "其他"}
	for _, iv := range ings {
		im, ok := iv.(map[string]any)
		if !ok {
			continue
		}
		in := getStr(im, "name")
		if in == "" {
			continue
		}
		if len([]rune(in)) > 20 {
			in = string([]rune(in)[:20])
		}
		outIngs = append(outIngs, map[string]any{
			"name":     in,
			"amount":   truncate(getStr(im, "amount"), 16),
			"category": pickAllowed(getStr(im, "category"), ingCats, "其他"),
		})
		if len(outIngs) >= 20 {
			break
		}
	}
	if len(outIngs) == 0 {
		return nil, "AI 返回缺少食材"
	}
	steps, _ := obj["steps"].([]any)
	outSteps := make([]string, 0, len(steps))
	for _, sv := range steps {
		ss, ok := sv.(string)
		if !ok || strings.TrimSpace(ss) == "" {
			continue
		}
		outSteps = append(outSteps, truncate(strings.TrimSpace(ss), 80))
		if len(outSteps) >= 12 {
			break
		}
	}
	if len(outSteps) == 0 {
		return nil, "AI 返回缺少步骤"
	}
	tips, _ := obj["tips"].([]any)
	outTips := make([]string, 0, 3)
	for _, tv := range tips {
		ts, ok := tv.(string)
		if !ok || strings.TrimSpace(ts) == "" {
			continue
		}
		outTips = append(outTips, truncate(strings.TrimSpace(ts), 60))
		if len(outTips) >= 3 {
			break
		}
	}
	emoji := getStr(obj, "emoji")
	if emoji == "" || len(emoji) > 8 {
		emoji = "🍽️"
	}
	out := map[string]any{
		"name": name, "emoji": emoji, "cuisine": cuisine, "taste": taste,
		"category": category, "type": typ,
		"isQuick":     clamp(getInt(obj, "durationMin"), 0, 240) > 0 && clamp(getInt(obj, "durationMin"), 0, 240) <= 30 && toBool(obj["isQuick"], clamp(getInt(obj, "durationMin"), 0, 240) <= 30),
		"durationMin": clamp(getInt(obj, "durationMin"), 0, 240),
		"difficulty":  clamp(getInt(obj, "difficulty"), 0, 5),
		"calories":    clamp(getInt(obj, "calories"), 0, 5000),
		"protein":     clamp(getInt(obj, "protein"), 0, 500),
		"fat":         clamp(getInt(obj, "fat"), 0, 500),
		"carbs":       clamp(getInt(obj, "carbs"), 0, 800),
		"ingredients": outIngs, "steps": outSteps, "tips": outTips,
	}
	if out["durationMin"].(int) == 0 {
		out["durationMin"] = 20
	}
	if out["difficulty"].(int) == 0 {
		out["difficulty"] = 2
	}
	if out["isQuick"].(bool) && out["durationMin"].(int) > 30 {
		out["isQuick"] = false
	}
	if isFridge {
		uses, _ := obj["uses"].([]any)
		outUses := make([]string, 0, len(uses))
		for _, uv := range uses {
			us, ok := uv.(string)
			if ok && strings.TrimSpace(us) != "" {
				outUses = append(outUses, truncate(strings.TrimSpace(us), 20))
			}
		}
		out["uses"] = outUses
	}
	return out, ""
}

func pickAllowed(v string, allowed []string, def string) string {
	for _, a := range allowed {
		if v == a {
			return a
		}
	}
	// 容错：给出的值包含某个允许值（如 "偏辣" → "辣"）
	for _, a := range allowed {
		if a != def && strings.Contains(v, a) {
			return a
		}
	}
	return def
}

func toBool(v any, def bool) bool {
	if b, ok := v.(bool); ok {
		return b
	}
	return def
}

func clamp(n, lo, hi int) int {
	if n < lo {
		return lo
	}
	if n > hi {
		return hi
	}
	return n
}

func truncate(s string, max int) string {
	r := []rune(strings.TrimSpace(s))
	if len(r) > max {
		return string(r[:max])
	}
	return string(r)
}

func truncateOpt(prefix, s string, max int) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	return prefix + truncate(s, max)
}

// chatRound 单轮调用 OpenAI 兼容 chat/completions，返回完整助手消息（含 tool_calls）与 usage。
// toolChoice 非空时透传（如强制调用某个工具）。
func chatRound(cfg llmConfig, msgs []chatMessage, tools []toolDef, toolChoice map[string]any,
	maxTokens int) (chatMessage, int64, int64, error) {
	body, _ := json.Marshal(chatRequest{
		Model:       cfg.Model,
		Messages:    msgs,
		Temperature: 0.7,
		MaxTokens:   maxTokens,
		Tools:       tools,
		ToolChoice:  toolChoice,
	})
	req, err := http.NewRequest("POST", cfg.BaseURL+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return chatMessage{}, 0, 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+cfg.APIKey)
	client := &http.Client{Timeout: 25 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return chatMessage{}, 0, 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return chatMessage{}, 0, 0, fmt.Errorf("http %d %s", resp.StatusCode, string(b))
	}
	var cr chatResponse
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&cr); err != nil {
		return chatMessage{}, 0, 0, err
	}
	if len(cr.Choices) == 0 {
		return chatMessage{}, 0, 0, fmt.Errorf("empty choices")
	}
	return cr.Choices[0].Message, int64(cr.Usage.PromptTokens), int64(cr.Usage.CompletionTokens), nil
}

// callChat 无工具的单轮对话（generate/fridge/substitute/recommend 普通模式沿用）
func callChat(cfg llmConfig, sys, user string, maxTokens int) (string, int64, int64, error) {
	msg, tin, tout, err := chatRound(cfg,
		[]chatMessage{{Role: "system", Content: sys}, {Role: "user", Content: user}}, nil, nil, maxTokens)
	if err != nil {
		return "", 0, 0, err
	}
	return msg.Content, tin, tout, nil
}

// callChatWithTools 带 function calling 循环的对话：LLM 请求工具时由 executor 执行并以
// tool 角色回填，直到 LLM 给出最终正文或达到轮次/次数上限。返回 (最终正文, 累计usage, 错误)。
// maxLLMCalls：本轮请求最多发起的 LLM 调用数；maxToolCalls：最多执行的工具次数。
// firstTool 非空时首轮用 tool_choice 强制调用该工具（不依赖模型自觉，保证开关语义）。
// 工具执行失败不中断循环——错误文本回给 LLM，由它降级处理（如只推库内菜）。
func callChatWithTools(cfg llmConfig, sys, user string, maxTokens int, tools []toolDef,
	executor func(name, args string) (string, error), maxLLMCalls, maxToolCalls int,
	firstTool string) (string, int64, int64, error) {
	msgs := []chatMessage{{Role: "system", Content: sys}, {Role: "user", Content: user}}
	var tin, tout int64
	toolUsed := 0
	for call := 1; call <= maxLLMCalls; call++ {
		// 收尾一轮（或工具次数用尽后）不再提供工具，强制 LLM 给出最终 JSON
		roundTools := tools
		roundChoice := map[string]any(nil)
		if call == 1 && firstTool != "" {
			roundChoice = map[string]any{"type": "function",
				"function": map[string]any{"name": firstTool}}
		}
		if call == maxLLMCalls || toolUsed >= maxToolCalls {
			roundTools = nil
			roundChoice = nil
		}
		msg, i, o, err := chatRound(cfg, msgs, roundTools, roundChoice, maxTokens)
		if err != nil {
			return "", tin, tout, err
		}
		tin += i
		tout += o
		if len(msg.ToolCalls) == 0 {
			return msg.Content, tin, tout, nil
		}
		msgs = append(msgs, msg)
		for _, tc := range msg.ToolCalls {
			if toolUsed >= maxToolCalls {
				msgs = append(msgs, chatMessage{Role: "tool", ToolCallID: tc.ID,
					Content: "工具调用次数已达本次上限，请直接给出最终回答。"})
				continue
			}
			toolUsed++
			out, terr := executor(tc.Function.Name, tc.Function.Arguments)
			if terr != nil {
				out = "工具执行失败：" + terr.Error()
			}
			msgs = append(msgs, chatMessage{Role: "tool", ToolCallID: tc.ID, Content: truncate(out, 4000)})
		}
	}
	// 理论上不可达（最后一轮无工具必有正文）；保险兜底
	return "", tin, tout, fmt.Errorf("工具循环未收敛")
}

// extractJSONObject 从模型输出中提取首个完整 JSON 对象（容忍 markdown 围栏/前后废话）
func extractJSONObject(text string) (map[string]any, error) {
	start := strings.Index(text, "{")
	if start < 0 {
		return nil, fmt.Errorf("no json")
	}
	depth := 0
	inStr := false
	escape := false
	for i := start; i < len(text); i++ {
		c := text[i]
		if escape {
			escape = false
			continue
		}
		switch {
		case c == '\\' && inStr:
			escape = true
		case c == '"':
			inStr = !inStr
		case c == '{' && !inStr:
			depth++
		case c == '}' && !inStr:
			depth--
			if depth == 0 {
				var out map[string]any
				if err := json.Unmarshal([]byte(text[start:i+1]), &out); err != nil {
					return nil, err
				}
				return out, nil
			}
		}
	}
	return nil, fmt.Errorf("unbalanced json")
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}
