# Pal：群聊 AI agent 競品研究與 hackathon MVP 建議

研究日期：2026 年 10 月 11 日。範圍涵蓋直接群聊競品、personal agents、社群貼文轉地圖、社交日曆，以及 YC／a16z Speedrun 的相關投資。這是公開資料研究，並未登入或實測產品；官方功能描述代表產品宣稱，不代表已驗證的可靠性。下方的 Pal 定位與 MVP 是研究後的建議。

**核心結論**

「群聊 + AI + 記憶 + 日曆 + reminders」已有直接競爭，尤其 Alfi 與 Continua。Alfi 更已明確使用讓群聊保持活躍的定位。Pal 最適合 hackathon 的切入點，是把群聊裡的生活計畫做完：分享想去的地方、整理選項、協調時間、確認活動、按時提醒。這能把「把時間還給人」變成可看見的成果。

建議產品句子：**Pal handles the planning, so you can spend more time together.**

這是聚焦建議，並非已驗證的市場空白。Alfi、Continua、Orbits，甚至部分地圖產品，都與這條流程有重疊；差異仍需用實際体验、可靠性與使用者訪談證明。

**競品地圖**

| 產品 | 關係與已查到的能力 | YC／Speedrun 證據 | Pal 可以參考什麼 |
| --- | --- | --- | --- |
| [Alfi / Text.ai](https://www.ycombinator.com/companies/text-ai) | 最直接競品。iOS／Android 群聊 app；群組偏好與記憶、Yelp 餐廳訂位、社交日曆、提醒、多人圖片生成、Group Wrapped；宣稱能判斷何時發言。 | YC Spring 2025，YC 官方頁確認。 | 把群聊作為主體；AI 記得誰吃素、預算與偏好；計畫有共同可見的結果。 |
| [Instinct](https://instinct.com/) | Personal agent；透過文字或電話委派生活任務，官網列出購物、預約、禮物與旅行規劃。 | [Sequoia 官方投資頁](https://sequoiacap.com/companies/instinct)可確認其支持；本輪未確認 YC／Speedrun 關係。 | 用很短的委派完成實際任務；長期記憶與工具执行是使用者感到 powerful 的來源。 |
| [Continua](https://blog.continua.ai/p/continua-is-social-ai) | 直接群聊競品。官方 2025 公告描述社交 AI、主動與適時參與、協助群體協作，減少把 AI 答案搬回群聊。 | 官方公告列出 GV 領投、Bessemer 參與的 800 萬美元 seed round。 | Agent 的「何時不要說話」也是產品能力。 |
| [Orbits / Bit](https://speedrun.a16z.com/companies/orbits) | 家庭群聊 agent；協調家庭成員、日曆、家務、採買與預約。官方 portfolio 明確描述 iMessage 家庭群聊中的 Bit。 | Speedrun SR007，官方 portfolio 確認。 | Shared context + proactive execution；把省時間聚焦在具體生活場景。 |
| [Chronicler](https://speedrun.a16z.com/companies/chronicler) | 把傳給自己的筆記、想法、提醒整理為可搜尋記憶，處理任務、排程、follow-up。 | Speedrun SR004，官方 portfolio 確認。 | 聊天是輸入，待辦與日曆是成果；使用者不用重填表單。 |
| [jo](https://www.ycombinator.com/companies/jo) | Personal agent；持續記憶、主動 briefings、autopilot recurring workflows、家庭協調。官方頁描述 Mac／web 已上線，native mobile 尚在規劃。 | YC 官方公司頁確認；頁面的 batch 與創辦人歷史敘述有差異，此處不推定原始 batch。 | 「現在不做、到時候再做」應是持久任務；家人仍各有私人記憶與分享邊界。 |
| [Pally](https://www.ycombinator.com/companies/pally) | Personal assistant；透過聊天接 inbox、calendar、files、tasks、web；公司歷史也包含跨平台人脈管理。 | YC Summer 2025，官方頁確認。 | Personal context 與自然語言委派；不需為 Pal MVP 重建所有個人資料整合。 |
| [Dola Calendar Assistant](https://heydola.com/) | 聊天管理日曆、提醒，舊官方 feature 頁描述 Google Calendar 同步。 | 本輪未確認 YC／Speedrun 關係。 | 行程卡片顯示時間、地點與提醒，避免自然語言歧義。 |
| [Hey Umai](https://www.heyumai.com/) | SMS wellness assistant；主動 check-ins、一次性／重複提醒、筆記。 | 本輪未確認 YC／Speedrun 關係。 | Follow-up 的語氣與節奏；無需下載 app 的低摩擦入口。 |
| [Meta AI](https://ai.meta.com/meta-ai/assistant/) | 既有社交與通訊 app 內的 AI，可提供推薦、計畫與群聊協助。 | 平台級競爭者。 | 自帶既有群聊分發優勢；Pal 必須讓搬入新 app 的價值清楚。 |
| [ChatGPT group chats](https://help.openai.com/en/articles/6825453-chatgpt-release-notes) | 人與 AI 共享對話的產品先例；目前官方已公告停止建立及加入新群聊。 | 平台級產品先例。 | 群聊 AI 有產品先例，但不能把曾推出的功能當成今天仍可新用的競品。 |
| [Plotline](https://getplotline.app/) | Instagram／TikTok 分享連結 → 自動抽取地點 → 地圖與旅遊規劃；官網描述 iOS，Android waitlist。 | 本輪未確認 YC／Speedrun 關係。 | 使用者分享內容的當下就保存場所與原始推薦脈絡。 |
| [Ready to Echo](https://readytoecho.com/) | 社群連結轉餐廳／地點、地圖、共享 Spaces、行程、群組投票、AI 協助選擇。 | 本輪未確認 YC／Speedrun 關係。 | 非常接近「連結 → 地點 → 群體決策」子流程；只有地圖抽取不夠形成差異。 |
| [Howbout](https://howbout.app/) | 社交共享日曆、朋友空閒時間、活動聊天；[官方 App Store 頁](https://apps.apple.com/ie/app/howbout-shared-calendar/id1477248221)描述日曆或 availability 的分享選擇。 | 本輪未確認 YC／Speedrun 關係。 | 用共同時間協調見面；不必公開每個人的私人行程名稱。 |
| [Partiful](https://partiful.com/) | 活動邀請、RSVP、日期投票、活動問題、群發更新與自動提醒。 | 不在本輪確認的 YC／Speedrun 名單內。 | 一張活動卡承載確定的計畫；[官方說明](https://help.partiful.com/en-us/articles/15525594-why-use-partiful)強調分享連結與提醒的低摩擦流程。 |
| [Cantina](https://cantina.com/) | Social AI characters、聊天、圖片／影片創作；當前首頁重點偏角色與內容創作。 | 本輪未確認 Speedrun 關係。 | 群體娛樂、人格與創作，可作未來方向；對省時間 demo 的幫助較小。 |
| [Sekai](https://speedrun.a16z.com/companies/sekai) | AI 互動內容與動漫 fan fiction；屬娛樂鄰近產品，並非群體日程協調競品。 | Speedrun SR003，官方 portfolio 確認。 | 若未來做群聊小遊戲，可參考共同參與的互動內容。 |

「未確認投資關係」表示沒有足夠證據，並非宣稱沒有投資。官方產品定位也不等於所有功能都可立即使用。

**三個最需要深入理解的競爭方向**

Alfi 是最值得實際體驗的產品：它與 Pal 的 mobile 群聊、記憶、聚會、reminders、讓群聊活躍的想法高度重疊。[官網](https://www.text.ai/)也公開列出訂位、活動、群組提醒與圖片創作。從公開資料推論，Pal 若只加更多工具，差異仍會模糊；應讓一條任務流程明顯更省操作、更容易確認、完成得更穩。

Instinct 值得學的是執行感。官方首頁只用簡單的委派入口與生活成果說明產品，不要求使用者理解 tools、agents 或 workflow。[2026/10/5 的報導](https://techcrunch.com/2026/10/05/instinct-brings-its-ai-agent-to-group-chats-even-for-friends-without-an-account/)指出其開始開放 early-access 群聊功能。原始創辦人 X 公告抓取受限，群聊時點以該報導為來源，未實測。不要再把它只視為 1:1 助理。

Orbits / Bit 的投資證據最貼近「把時間還給人」。Speedrun 官方描述它在家庭群聊協調多人生活任務，而非只回答問題。[公司 2026/9/16 的公告](https://tryorbits.com/press/orbits-raises-pre-seed-round-ai-home-manager)確認約 200 萬美元的 pre-seed，約等於 260 萬加幣；不能把標題的 2.6M 當成美元。Pal 可以參考它對使用者與生活瑣事的聚焦，但 hackathon 不需承接家庭的所有執行工作。

**現況與歷史資料要分開**

- ChatGPT：官方 release notes 於 2026/7/9 公告，不能再建立新 group chats、把既有對話變成群聊或透過邀請加入；既有群聊可暫時繼續使用。因此把它列為產品先例，不當成可新建群聊的 active benchmark。[官方來源](https://help.openai.com/en/articles/6825453-chatgpt-release-notes)
- Continua：2025 官方文章確認群聊方向與投資；目前 continua.ai 首頁可抓取內容只有 Wheelie 標題與少量連結，不能據此確認原群聊體驗今天的可用範圍。[推出公告](https://blog.continua.ai/p/introducing-text-with-continua)、[融資與定位](https://blog.continua.ai/p/continua-is-social-ai)
- Martin：2024 年創辦人在 [Launch HN](https://news.ycombinator.com/item?id=41119443)介紹 YC S23 的 personal assistant；但現在 YC 的 /companies/martin 會轉到 [Letterbook](https://www.ycombinator.com/companies/letterbook)，定位已是客服。因此保留為歷史參考，不直接列為現在活躍的 consumer assistant。
- mixus：早期媒體介紹過 multiplayer AI chat；[當前官方首頁](https://www.mixus.ai/)則主打律師透過 email／Word 使用與審核 agent 成果。當作協作產品演變案例，不能沿用舊描述。
- Dola：此處指 heydola.com 的日曆 assistant；搜尋亦有 dola.com 的另一個通用 AI 產品，沒有證據支持把兩者合併。日曆產品搜尋資料較舊，feature 頁本次直接抓取回傳 502，今日可用性待測。
- Alfi：官網不同區塊的訊息量數字並不一致；本報告不拿流量數字判定市場規模或成熟度。

**對 Pal 的產品推論**

群聊 agent 比個人 chatbot 多了三個產品責任：知道誰說了什麼與對誰提出請求；知道什麼是提議、什麼已得到確認；知道什麼時候該執行、追問或保持安靜。單純記住所有聊天，並不會自動完成這些工作。

「Alive」可以定義成未完成的計畫仍有人照顧，而不必讓 agent 不斷發話。例子：大家已選餐廳，但兩人尚未確認時間；Pal 記住這件事，在大家同意的時間追問一次，確認完成後停止。這比無目的地聊天更符合省時間主題。

如果用 harness 描述技術方向，對本 MVP 最小的含義是：共同上下文、少數任務工具、持久排程與清楚的行動權限。使用者介面仍只需看見計畫與結果。

**建議 MVP：朋友週末約飯，一條完整流程**

Instagram／TikTok 的口述例子可能包含帳號或內容比較。本建議先採最容易 demo 的「朋友分享餐廳貼文／連結」情境；帳號級分析是另一條需求，不與這次規劃混在一起。

1. 三位朋友在群聊分享兩個想去的地方，講出預算、飲食限制與大概時間。Pal 讀取這個群組中可存取的對話，辨認需求。
2. Pal 整理兩張可確認的地點卡，保留原始連結與地址，在同一張小地圖比較位置；缺少地點時讓人補充，不能臆造。
3. Pal 提出最多兩個時間。最小版本從聊天與時間投票收集 availability；若時間與授權流程允許，再加各自 Google Calendar 的 free/busy 查詢。
4. 大家確認後，Pal 把地點、日期、時間和參加者收斂成一張共享活動卡。最低限度提供加入個人日曆入口；真正寫入各人 Google Calendar 是另一個明確授權動作，不能把匯出行程當成已完成同步。
5. Pal 記錄一次有期限的 follow-up：先讓群組看見它會在何時提醒、提醒什麼；時間到真的送出，再可取消。舞台 demo 可使用一分鐘後的示範提醒，並明示這是加速示範。

最低應真正完成：多人訊息進入同一群組、AI 依對話整理結果、共享活動狀態保存、一次到期提醒。若只是逐頁播放假資料，無法證明 agent 的行動能力。

地點抽取、每人日曆 OAuth 與推播都是可分離的整合風險。完整影片理解若來不及，先接受連結加文字／截圖、讓使用者確認地點；demo 清楚標示使用了哪些輸入。沒有做 live OAuth，就明說時間來自聊天，避免暗示已讀取私人日曆。

**乾淨的 mobile 體驗**

只需要群聊列表、群聊主畫面，以及從活動卡打開的計畫詳情。群聊是主畫面；顶部顯示當前已確認的計畫，訊息裡嵌入地點卡、時間選項與活動卡；地圖、參加者、日曆與提醒設定放在詳情。避免為每種工具增加一個導航頁。

Pal 一次回覆只需短句加可操作的卡片。例如：「找到兩個地方；A 符合素食和每人 $30 的預算。你們想約週六 7 點嗎？」活動狀態以文字清楚區分「建議中／待確認／已確定／已提醒」，不能只靠顏色。

記憶應能追溯來源並允許更正。群组知道 Pal 能讀取與保留哪些聊天；個人的日曆內容與私聊不能自動分享給所有人。對協調時間，群組通常只需要知道共同可行時段。任何行程改動或取消也應有清楚的狀態和確認。

**兩分鐘 demo 與省時間證據**

開場展示熟悉的麻煩：群聊丟了一堆餐廳連結，沒人確定地址、誰能吃、誰有空，也沒人想負責追問。接著完整演示連結整理、選時間、活動確認與一次 follow-up。收尾時所有人都能看到同一個確定計畫。

呈現省時間時，先量同一場景的人工與 Pal 流程：完成時間、切換 app 次數、手動搬運資訊次數、需要人追問幾次。報告實際量到的結果；未量之前不宣稱省下固定幾小時，也不把「讓群聊訊息增加」當作省時間成效。

**此次先不做**

小遊戲、角色商城、多人圖片生成、泛用 agent builder、整批社群帳號研究、完整影片抓取系統、多平台聊天匯入、自動付款／訂位、完整家庭 life OS，以及用估計值裝飾的 time-saved dashboard。這些都不影響「群聊中的計畫真的完成」的第一個證明。

下一個具體動作：用「三個朋友、兩個餐廳連結、一次約飯」畫出上述三個 mobile 畫面與兩分鐘 demo script，再開始實作最小流程。

尚未登入實測產品、驗證留存／營收或測量省時效果；本輪是代表性競品研究，並非窮盡市場。
主要風險是 Alfi 的定位重疊，以及社群內容抽取與多人日曆授權會吃掉 hackathon 時間；先把一條真實可完成的流程做穩。
