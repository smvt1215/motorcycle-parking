import { Site } from '../ui/Site';
import './Roadmap.css';

const STAGES = [
  {
    title: '正在做',
    stage: '邀請試用',
    tone: 'deep',
    items: [
      '新版新增與修改停車點表單：依分區和路段填寫能不能停、怎麼算錢',
      '依分區和路段的車友現場回報',
      'App 內直接用 Google 或 Apple 登入',
      '隱藏車友與檢舉不當內容',
    ],
  },
  {
    title: '接下來',
    stage: '開放試用',
    tone: 'dark',
    items: [
      '規則離線更新與縣市規則更新通知',
      '依車種的時段禁停判斷',
      '整理社群地圖的限時開放與費率資料',
      '重機可停汽車格的空位顯示（臺北）',
      '貢獻等級、徽章和每月縣市排行榜：認真回報的車友累積等級與徽章；排行榜可自行選擇是否加入',
    ],
  },
  {
    title: '之後',
    stage: '開放試用之後',
    tone: 'light',
    items: ['自助匯出個人資料', '回報時上傳公告照片'],
  },
] as const;

/** /roadmap (canvas boards Roadmap and PhoneRoadmap). */
export function Roadmap() {
  return (
    <Site>
      <div className="roadmap">
        <div className="roadmap-head">
          <h1>接下來</h1>
          <p>計畫可能調整，做到哪裡就更新到哪裡。</p>
        </div>
        <div className="roadmap-stages">
          {STAGES.map((stage) => (
            <section key={stage.title} className={`roadmap-stage roadmap-stage--${stage.tone}`}>
              <div className="roadmap-stage-head">
                <h2>{stage.title}</h2>
                <span>{stage.stage}</span>
              </div>
              <ul>
                {stage.items.map((item) => (
                  <li key={item}>{item}</li>
                ))}
              </ul>
            </section>
          ))}
        </div>
      </div>
    </Site>
  );
}
