# 政策追踪系统（ESG / 双碳 / 电力 / 碳市场）

自动监控 **国务院** 及 **6 个部委** 网站的政策更新，命中关键词后生成报告并弹窗提醒。

## 一、监控范围

| 来源 | 网址 | 说明 |
|------|------|------|
| 国务院（中国政府网） | https://www.gov.cn/zhengce/ | 最新政策 |
| 生态环境部 | https://www.mee.gov.cn/zcwj/ | 政策文件 |
| 国家发展改革委 | https://www.ndrc.gov.cn/xxgk/zcfb/tz/ | 政策·通知 |
| 国家能源局 | https://www.nea.gov.cn/ | 首页（含通知公告） |
| 财政部 | https://www.mof.gov.cn/zhengwuxinxi/zhengcefabu/ | 政策发布 |
| 市场监管总局 | https://www.samr.gov.cn/ | 首页（子栏目 JS 渲染，覆盖有限） |
| 工业和信息化部 | https://wap.miit.gov.cn/ | 首页（最新政策/工信动态，与 www 同源） |

## 二、文件说明

| 文件 | 作用 |
|------|------|
| `check.ps1` | 主脚本：抓取→匹配→去重→报告→提醒 |
| `keywords.txt` | 关键词（每行一个，`#` 开头为注释） |
| `sources.json` | 监控来源配置 |
| `seen.json` | 已记录条目（自动维护，用于去重） |
| `dashboard-template.html` | 网页台账模板（版式在此改，含占位符） |
| `政策追踪.html` | 自动生成的网页台账（浏览器打开） |
| `reports/` | 新增报告（按时间戳命名） |
| `log/run.log` | 运行日志 |

## 三、如何使用

### 手动运行一次

```powershell
powershell -NoProfile -File "D:\法律法规追踪正式\check.ps1"
```

- 默认回看 **45 天**；可用 `-DaysBack 90` 调整。
- 用 `-TestLocal` 离线测试（读取 `.tmp/` 里的网页快照，不联网）。

### 定时任务（已注册）

- **任务名**：`政策追踪-月度检查`
- **触发**：每月第三个周四 09:00
- **动作**：`powershell.exe -NoProfile -WindowStyle Hidden -File D:\法律法规追踪正式\check.ps1`
- 命中新增时：写入 `reports/新增_日期.md` + 桌面气泡提醒（交互会话下）。

查看/修改定时任务：

```powershell
Get-ScheduledTask -TaskName "政策追踪-月度检查"
# 改时间（示例：改成每月第三个周四 14:30）
schtasks /Change /TN "政策追踪-月度检查" /ST 14:30
# 删除
schtasks /Delete /TN "政策追踪-月度检查" /F
```

## 四、修改关键词 / 来源

- 关键词：编辑 `keywords.txt`，每行一个（中文按字面、英文不区分大小写）。
- 来源：编辑 `sources.json`，字段 `name`（名称）、`url`（列表页）、`base`（域名）、`testFile`（离线测试快照路径）。

## 五、已知限制

1. **只抓列表页首页**：每个来源仅解析列表页第一屏，不翻页。对“每月新增”足够；但对“回溯更早”会漏掉已滚出首页的旧条目。
2. **JS 渲染的子栏目抓不到**：市场监管总局、能源局的子栏目（通知公告等）为 JS 动态加载，脚本只能覆盖其首页静态部分。
3. **中文编码已处理**：脚本用「原始字节 + 编码探测（UTF-8/GB2312）」解码，避免 `Invoke-WebRequest` 对中文站点的错误解码。
4. **提醒依赖交互会话**：桌面气泡仅在有图形界面登录时显示；报告文件与日志始终写入，可事后查看。
