// ==================== 小红书灵感（xiaohongshu-mcp REST 客户端） ====================
// 上游是 github.com/xpzouying/xiaohongshu-mcp：同一服务同时暴露 MCP 协议端点
// 与普通 REST API（/api/v1/*），这里走 REST 面，保持本服务零第三方依赖。
// 只用「搜索笔记」「笔记详情」两个能力，供问AI助手（recommend）web 模式作灵感检索；
// 不做任何发布/评论/点赞等写操作。
//
// 爬取纪律（账号安全）：结果按关键词缓存 6h、笔记详情按 feedId 缓存 6h、
// 真实上游搜索全局日限 WTE_XHS_DAILY_LIMIT（默认 40 次，缓存命中不计）。
//
// 配置：WTE_XHS_BASE_URL（未配置=功能整体关闭）、WTE_XHS_TOKEN（上游 Bearer）、
// WTE_XHS_DAILY_LIMIT。
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// xhsNote 搜索结果的单条笔记（工具结果给 LLM 时不带 feedId/xsecToken，
// 只带序号 ref；服务端用映射表把 LLM 引用的 ref 硬解析回链接，防 URL 幻觉）
type xhsNote struct {
	Title     string `json:"title"`
	Author    string `json:"author"`
	Likes     string `json:"likes"`
	FeedID    string `json:"-"`
	XsecToken string `json:"-"`
}

type xhsConfig struct {
	BaseURL    string
	Token      string
	DailyLimit int
}

// loadXHSConfig 读取小红书客户端配置；BaseURL 为空表示未配置（功能关闭）
func loadXHSConfig() xhsConfig {
	cfg := xhsConfig{
		BaseURL:    strings.TrimRight(os.Getenv("WTE_XHS_BASE_URL"), "/"),
		Token:      os.Getenv("WTE_XHS_TOKEN"),
		DailyLimit: 40,
	}
	if v := os.Getenv("WTE_XHS_DAILY_LIMIT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			cfg.DailyLimit = n
		}
	}
	return cfg
}

// xhsConfigured 功能是否已配置（/health 透出 + 端侧决定是否显示开关）
func xhsConfigured() bool {
	return loadXHSConfig().BaseURL != ""
}

// xhsNoteURL 组装网页版笔记链接（xsec_token 是网页打开的必要参数）
func xhsNoteURL(n xhsNote) string {
	return "https://www.xiaohongshu.com/explore/" + url.PathEscape(n.FeedID) +
		"?xsec_token=" + url.QueryEscape(n.XsecToken)
}

var xhsClient = &http.Client{Timeout: 20 * time.Second}

// xhsCall 上游 REST 调用（{success,data,message}/{error,code} 包装），data 回填 raw
func xhsCall(cfg xhsConfig, method, path string, body any) (json.RawMessage, error) {
	var rd io.Reader
	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		rd = bytes.NewReader(buf)
	}
	req, err := http.NewRequest(method, cfg.BaseURL+path, rd)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if cfg.Token != "" {
		req.Header.Set("Authorization", "Bearer "+cfg.Token)
	}
	resp, err := xhsClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var out struct {
		Success bool            `json:"success"`
		Data    json.RawMessage `json:"data"`
		Message string          `json:"message"`
		Error   string          `json:"error"`
		Code    string          `json:"code"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&out); err != nil {
		return nil, fmt.Errorf("上游响应异常(http %d)", resp.StatusCode)
	}
	if resp.StatusCode != 200 || !out.Success {
		return nil, fmt.Errorf("%s(%s)", out.Error, out.Code)
	}
	return out.Data, nil
}

// ---------- 搜索（缓存 + 日限流） ----------

const xhsCacheTTL = 6 * time.Hour

var (
	xhsMu       sync.Mutex
	xhsCache    = map[string]xhsCacheEntry{} // 关键词 → 结果
	xhsDetail   = map[string]xhsDetailEntry{} // feedId → 正文
	xhsCountDay string
	xhsCount    int
)

type xhsCacheEntry struct {
	notes []xhsNote
	at    time.Time
}

type xhsDetailEntry struct {
	text string
	at   time.Time
}

// xhsTakeQuota 全局日计数（真实上游搜索才消耗）；超限返回 false
func xhsTakeQuota(cfg xhsConfig) bool {
	xhsMu.Lock()
	defer xhsMu.Unlock()
	today := time.Now().Format("2006-01-02")
	if xhsCountDay != today {
		xhsCountDay = today
		xhsCount = 0
	}
	if xhsCount >= cfg.DailyLimit {
		return false
	}
	xhsCount++
	return true
}

// xhsSearchRaw 按关键词搜索笔记（最多 8 条）。缓存命中不消耗日配额。
func xhsSearchRaw(keyword string) ([]xhsNote, error) {
	keyword = strings.TrimSpace(keyword)
	if keyword == "" {
		return nil, errors.New("关键词为空")
	}
	cfg := loadXHSConfig()
	if cfg.BaseURL == "" {
		return nil, errors.New("小红书功能未配置")
	}
	now := time.Now()
	xhsMu.Lock()
	if e, ok := xhsCache[keyword]; ok && now.Sub(e.at) < xhsCacheTTL {
		xhsMu.Unlock()
		return e.notes, nil
	}
	// 缓存满：先清过期，仍满则整体重置（夫妻双用户场景，量级极小）
	if len(xhsCache) >= 100 {
		for k, e := range xhsCache {
			if now.Sub(e.at) >= xhsCacheTTL {
				delete(xhsCache, k)
			}
		}
		if len(xhsCache) >= 100 {
			xhsCache = map[string]xhsCacheEntry{}
		}
	}
	xhsMu.Unlock()

	if !xhsTakeQuota(cfg) {
		return nil, fmt.Errorf("已达今日小红书查询上限（%d 次）", cfg.DailyLimit)
	}
	data, err := xhsCall(cfg, http.MethodPost, "/api/v1/feeds/search", map[string]any{"keyword": keyword})
	if err != nil {
		return nil, err
	}
	var sd struct {
		Feeds []struct {
			XsecToken string `json:"xsecToken"`
			ID        string `json:"id"`
			ModelType string `json:"modelType"`
			NoteCard  struct {
				DisplayTitle string `json:"displayTitle"`
				User         struct {
					Nickname string `json:"nickname"`
					NickName string `json:"nickName"`
				} `json:"user"`
				InteractInfo struct {
					LikedCount string `json:"likedCount"`
				} `json:"interactInfo"`
			} `json:"noteCard"`
		} `json:"feeds"`
	}
	if err := json.Unmarshal(data, &sd); err != nil {
		return nil, errors.New("搜索结果解析失败")
	}
	notes := make([]xhsNote, 0, 8)
	for _, f := range sd.Feeds {
		// 过滤直播卡片/热词等非笔记条目（与上游 onlyNotes 同判据）
		if f.ModelType != "note" || f.ID == "" {
			continue
		}
		author := f.NoteCard.User.Nickname
		if author == "" {
			author = f.NoteCard.User.NickName
		}
		notes = append(notes, xhsNote{
			Title:     truncate(f.NoteCard.DisplayTitle, 60),
			Author:    truncate(author, 20),
			Likes:     truncate(f.NoteCard.InteractInfo.LikedCount, 10),
			FeedID:    f.ID,
			XsecToken: f.XsecToken,
		})
		if len(notes) >= 8 {
			break
		}
	}
	xhsMu.Lock()
	xhsCache[keyword] = xhsCacheEntry{notes: notes, at: now}
	xhsMu.Unlock()
	return notes, nil
}

// ---------- 笔记详情（缓存） ----------

// xhsNoteDetail 取笔记正文文本（标题+描述，截断 800 字），带 feedId 级缓存。
// 只用于 LLM 提炼灵感摘要，不对外透出原文。
func xhsNoteDetail(feedID, xsecToken string) (string, error) {
	cfg := loadXHSConfig()
	if cfg.BaseURL == "" {
		return "", errors.New("小红书功能未配置")
	}
	now := time.Now()
	xhsMu.Lock()
	if e, ok := xhsDetail[feedID]; ok && now.Sub(e.at) < xhsCacheTTL {
		xhsMu.Unlock()
		return e.text, nil
	}
	if len(xhsDetail) >= 50 {
		for k, e := range xhsDetail {
			if now.Sub(e.at) >= xhsCacheTTL {
				delete(xhsDetail, k)
			}
		}
		if len(xhsDetail) >= 50 {
			xhsDetail = map[string]xhsDetailEntry{}
		}
	}
	xhsMu.Unlock()

	data, err := xhsCall(cfg, http.MethodPost, "/api/v1/feeds/detail", map[string]any{
		"feed_id": feedID, "xsec_token": xsecToken,
	})
	if err != nil {
		return "", err
	}
	var dd struct {
		Data struct {
			Note struct {
				Title string `json:"title"`
				Desc  string `json:"desc"`
			} `json:"note"`
		} `json:"data"`
	}
	if err := json.Unmarshal(data, &dd); err != nil {
		return "", errors.New("笔记详情解析失败")
	}
	text := truncate(strings.TrimSpace(dd.Data.Note.Title+" "+dd.Data.Note.Desc), 800)
	if text == "" {
		return "", errors.New("笔记没有可读内容")
	}
	xhsMu.Lock()
	xhsDetail[feedID] = xhsDetailEntry{text: text, at: now}
	xhsMu.Unlock()
	return text, nil
}
