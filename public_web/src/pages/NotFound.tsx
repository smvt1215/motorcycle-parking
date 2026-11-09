import { Link } from 'react-router';
import { Site } from '../ui/Site';

export function NotFound() {
  return (
    <Site>
      <div style={{ padding: '28px 16px', maxWidth: 560, margin: '0 auto', display: 'grid', gap: 12 }}>
        <h1 style={{ margin: 0, fontSize: 28, fontWeight: 900 }}>找不到這個頁面</h1>
        <p style={{ margin: 0, fontSize: 15, lineHeight: 1.7 }}>網址可能打錯了，或這個頁面已經移除。</p>
        <Link to="/" style={{ fontSize: 15, fontWeight: 700, padding: '12px 0' }}>
          回首頁
        </Link>
      </div>
    </Site>
  );
}
