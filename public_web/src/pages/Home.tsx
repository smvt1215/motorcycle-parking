import { Link } from 'react-router';
import { Site } from '../ui/Site';
import { Street } from '../ui/Street';
import './Home.css';

/** The cards after 找停車點, whose map makes it a different shape. */
const CARDS = [
  { title: '查停車規則', body: '各縣市機車與大型重機的停車規定整理在一起。', tone: 'mist' },
  { title: '記住停車位置', body: '儲存停車位置與備註，計時提醒，避免超時。', tone: 'plain' },
  { title: '怎麼算錢', body: '看懂每個點怎麼收費，停多久大概要付多少。', tone: 'plain' },
  { title: '車友現場回報', body: '看看其他車友剛回報的現場狀況，也可以回報你看到的。', tone: 'mist' },
  { title: '即時空位 Beta', body: '部分地點可以看即時空位，資料可能延遲或中斷。', tone: 'plain' },
] as const;

const STACK = [
  { title: '依車種', body: '各縣市普通機車與大型重機的停車規定整理在一起。', tone: 'plain' },
  { title: '依時段', body: '汽機車共用格依時段判斷能不能停。', tone: 'mist' },
  { title: '依來源', body: '官方資料與車友回報分開標示，車友回報經審核後公開。', tone: 'deep' },
] as const;

/**
 * The home page (canvas boards Home and PhoneHome). The cards stack on scroll
 * through CSS only: without support, or with reduced motion, it is the same
 * page standing still.
 */
export function Home() {
  return (
    <Site overlay>
      <section className="home-hero">
        <Street width={1280} height={760} className="street street--wide" />
        <Street width={390} height={620} className="street street--narrow" />
        <div className="home-hero-shade" />
        <div className="home-hero-body">
          <h1>
            騎到之前，先知道
            <br />
            這裡能不能停。
          </h1>
          <p className="home-hero-lead">找普通機車與大型重機能停的地方，查各縣市規則，記住停車位置。</p>
          <div className="home-actions">
            <Link to="/#how" className="home-cta home-cta--yellow">
              看看怎麼用
            </Link>
            <Link to="/support" className="home-cta home-cta--ghost">
              聯絡我們
            </Link>
          </div>
          <p className="home-hero-note">即將在 App Store 與 Google Play 推出</p>
        </div>
      </section>

      <section id="features" className="home-section home-features">
        <h2 className="home-features-title">
          同一條路，普通機車
          <span className="home-lane-pill" aria-hidden="true">
            <span />
          </span>
          和大型重機的答案可能不一樣。
        </h2>
        <div className="home-bento">
          <div className="home-card home-card--map">
            <Street width={744} height={516} className="street street--wide" />
            <Street width={358} height={300} className="street street--narrow" />
            <div className="home-card-shade" />
            <div className="home-card-text">
              <h3>找停車點</h3>
              <p>依車種查看附近的機車停車場、路邊停車格與汽機車共用格。</p>
            </div>
          </div>
          {CARDS.map((card) => (
            <div key={card.title} className={`home-card home-card--${card.tone}`}>
              <h3>{card.title}</h3>
              <p>{card.body}</p>
            </div>
          ))}
          <div className="home-card home-card--dark">
            <div className="home-card-text">
              <h3>一起補齊資料</h3>
              <p>回報新的停車點，或建議修改既有資訊；回報經審核後公開。</p>
            </div>
            <svg className="home-card-lane" width="220" height="10" aria-hidden="true">
              <path d="M0 5H220" stroke="#F2C200" strokeWidth="3" strokeDasharray="20 16" />
            </svg>
          </div>
        </div>
      </section>

      <section id="how" className="home-section home-steps-section">
        <h2>三步就知道能不能停</h2>
        {/* role="list": Safari drops the list semantics of a styled list. */}
        <ol className="home-steps" role="list">
          <li className="home-step home-step--current">
            <span className="home-step-title">選車種</span>
            <span className="home-step-body">普通機車或大型重機，看到的結論就是你的車的。</span>
          </li>
          <li className="home-step">
            <span className="home-step-title">看結論</span>
          </li>
          <li className="home-step">
            <span className="home-step-title">記位置</span>
          </li>
        </ol>
      </section>

      <section id="rules" className="home-section home-rules">
        <div className="home-rules-lead">
          <h2>資料從哪裡來、適用什麼時候，都分清楚。</h2>
          <p>停車條件依車種、路段與現場標示而異，請以現場公告為準。</p>
        </div>
        <div className="home-stack">
          {STACK.map((card) => (
            <div key={card.title} className={`home-card home-stack-card home-card--${card.tone}`}>
              <h3>{card.title}</h3>
              <p>{card.body}</p>
            </div>
          ))}
        </div>
      </section>

      <section className="home-band">
        <div className="home-band-inner">
          <div className="home-band-text">
            <h2>即將推出</h2>
            <p>上架後，下載連結會放在這裡。想知道接下來要做什麼，可以先看計畫。</p>
          </div>
          <div className="home-actions home-actions--band">
            <Link to="/roadmap" className="home-cta home-cta--yellow">
              看接下來的計畫
            </Link>
            <Link to="/support" className="home-cta home-cta--ghost">
              聯絡我們
            </Link>
          </div>
        </div>
      </section>
    </Site>
  );
}
