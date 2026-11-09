import type { ContentReport, ContentReportText, TimedCase } from '../api/v1/admin_v1.generated';
import { useDataConnection } from '../app/connection';
import { dateTime } from './model';
import { DefinitionList, Notice, Tag } from './CaseParts';

/** Field → label; a report can only ask about these. */
const TEXT_LABELS: [keyof ContentReportText, string][] = [
  ['contributor_name', '車友名稱'],
  ['name', '停車點名稱'],
  ['note', '其他備註'],
  ['entrance_note', '入口說明'],
  ['parking_guide', '停放方式'],
  ['special_rules', '特殊規定'],
];

/** Which fields each kind of report is about (private.content_hold_parts). */
const TARGET_FIELDS: Record<string, (keyof ContentReportText)[]> = {
  rider_name: ['contributor_name'],
  spot_name: ['name'],
  text: ['note', 'entrance_note', 'parking_guide', 'special_rules'],
  impersonation: ['contributor_name', 'name', 'note', 'entrance_note', 'parking_guide', 'special_rules'],
};

export function reportFields(report: ContentReport): [keyof ContentReportText, string][] {
  const wanted = TARGET_FIELDS[report.target];
  return TEXT_LABELS.filter(([key]) =>
    wanted ? wanted.includes(key) : (report.current[key] ?? report.snapshot[key] ?? '') !== '',
  );
}

export const reportFieldLabel = (key: string) => TEXT_LABELS.find(([field]) => field === key)?.[1] ?? key;

/** What riders currently see. Only parts under review differ from the text. */
function appShows(report: ContentReport): string {
  const parts = report.content_held;
  const shown: string[] = [];
  if (parts.includes('spot_name')) shown.push('名稱審核中');
  if (parts.includes('rider_name')) shown.push('車友名稱不顯示');
  if (parts.includes('text')) shown.push('說明文字不顯示');
  return shown.length > 0 ? shown.join('、') : '和目前原文相同';
}

function ContentTable({ report }: { report: ContentReport }) {
  const fields = reportFields(report);
  return (
    <div className="case-table-wrap">
      <table className="case-table">
        <thead>
          <tr>
            <th scope="col">欄位</th>
            <th scope="col">檢舉當下</th>
            <th scope="col">目前原文</th>
          </tr>
        </thead>
        <tbody>
          {fields.map(([key, label]) => {
            const before = report.snapshot[key] ?? '';
            const current = report.current[key] ?? '';
            const changed = before !== current;
            return (
              <tr key={key}>
                <th scope="row">{label}</th>
                <td data-label="檢舉當下">{before || <span className="muted">（空白）</span>}</td>
                <td data-label="目前原文" className={changed ? 'is-changed' : undefined}>
                  {current || <span className="muted">（空白）</span>}
                  {changed && (
                    <span className="case-table__tag">
                      <span className="modified-tag">檢舉後已改</span>
                    </span>
                  )}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

export function ReportNotices({ item, report }: { item: TimedCase; report: ContentReport }) {
  const hidden = report.content_held.length > 0;
  return (
    <>
      {report.spot_deleted && (
        <Notice title="內容已不存在">
          被檢舉的內容隨點位一起刪除了，App 上已看不到。按結案關閉這{' '}
          <span className="num">{report.reports.length}</span> 則檢舉。
        </Notice>
      )}
      {!report.spot_deleted && item.bucket === 'overdue' && hidden && (
        <Notice tone="alert" title="內容繼續隱藏">
          超過處理期限不會自動放回，也不會自動成立，要等管理員處理。
        </Notice>
      )}
      {!report.spot_deleted && report.target === 'rider_name' && (
        <Notice title="只有兩個選項">車友名稱不能修改，所以沒有「改內容」。</Notice>
      )}
      {!report.spot_deleted && report.target === 'impersonation' && (
        <Notice title="車友名稱、停車點名稱和說明文字都已隱藏">
          不成立會全部放回。成立要填新的停車點名稱，車友名稱清除，說明文字移除。
        </Notice>
      )}
      {!report.spot_deleted && !hidden && (
        <Notice title="內容還顯示在 App">
          這類檢舉不會自動隱藏。不成立就結案；成立就改內容，或按檢舉成立結案。
        </Notice>
      )}
    </>
  );
}

export function ReportBody({ report, now }: { report: ContentReport; now: number }) {
  const connection = useDataConnection();
  const count = report.reports.length;
  // The spot page is Flutter on the deployed site: a separate tab keeps this one's drafts.
  const external = connection === 'live';
  return (
    <>
      <DefinitionList
        rows={[
          [
            '點位',
            report.spot_deleted ? (
              '點位已刪除'
            ) : (
              <a
                href={`/spots/${encodeURIComponent(report.spot_id)}`}
                {...(external ? { target: '_blank', rel: 'noopener' } : {})}
              >
                開啟這個點位
              </a>
            ),
          ],
          ['App 目前顯示', report.spot_deleted ? '已看不到' : appShows(report)],
        ]}
      />
      {!report.spot_deleted && (
        <section aria-labelledby="case-content" className="case-section">
          <h3 id="case-content" className="t-title">
            被檢舉的內容
          </h3>
          <ContentTable report={report} />
        </section>
      )}
      <section aria-labelledby="case-reports" className="case-section">
        <h3 id="case-reports" className="t-title">
          檢舉 <span className="num">{count}</span> 則
        </h3>
        <ol className="case-reports">
          {report.reports.map((entry) => (
            <li key={entry.id}>
              <span className="case-message__head">
                <span>{entry.note || <span className="muted">沒有補充說明</span>}</span>
                <span className="num t-caption">{dateTime(entry.created_at, now)}</span>
              </span>
              {(entry.held || entry.same_network) && (
                <span className="case-reports__tags">
                  {entry.held && <Tag tag={{ label: '觸發暫時隱藏', tone: 'outline' }} />}
                  {entry.same_network && <Tag tag={{ label: '和另一則同網路', tone: 'dashed' }} />}
                </span>
              )}
            </li>
          ))}
        </ol>
        {count > 1 && (
          <span className="t-caption">
            處理後，這 <span className="num">{count}</span> 則會一起結案。
          </span>
        )}
      </section>
    </>
  );
}
