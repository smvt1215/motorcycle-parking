import { Navigate, type RouteObject } from 'react-router';
import { DesignPage } from '../pages/DesignPage';
import { ImportPage, MorePage, NotFoundPage, RulesPage, SpotsPage, UsersPage } from '../pages/SectionPages';
import { ReviewDetail } from '../review/ReviewDetail';
import { ReviewIndex } from '../review/ReviewIndex';
import { ReviewPage } from '../review/ReviewPage';
import { AppShell } from '../shell/AppShell';

export const routes: RouteObject[] = [
  {
    path: '/',
    Component: AppShell,
    children: [
      { index: true, element: <Navigate to="/review" replace /> },
      {
        // The queue stays mounted while the detail follows the URL.
        path: 'review',
        Component: ReviewPage,
        children: [
          { index: true, Component: ReviewIndex },
          { path: ':reportId', Component: ReviewDetail },
        ],
      },
      { path: 'spots', Component: SpotsPage },
      { path: 'rules', Component: RulesPage },
      { path: 'import', Component: ImportPage },
      { path: 'users', Component: UsersPage },
      { path: 'more', Component: MorePage },
      { path: 'design', Component: DesignPage },
      { path: '*', Component: NotFoundPage },
    ],
  },
];
