import { Page } from '../pages/Page';
import { LineIcon } from '../ui/icons';
import { SECTIONS, sectionHref } from './sections';

/** 更多 on the deployed site: the sections the phone tabs have no room for. */
export function MoreLinks() {
  return (
    <Page title="更多">
      <ul className="link-list panel" aria-label="其他功能">
        {SECTIONS.filter((section) => !section.phoneTab).map((section) => (
          <li key={section.path}>
            <a href={sectionHref(section)}>
              <LineIcon name={section.icon} />
              {section.label}
            </a>
          </li>
        ))}
      </ul>
    </Page>
  );
}
