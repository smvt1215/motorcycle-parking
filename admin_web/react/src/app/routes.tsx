import { Navigate, type RouteObject } from 'react-router';
import { DesignPage } from '../pages/DesignPage';
import {
  ImportPage,
  MorePage,
  NotFoundPage,
  ReviewPage,
  RulesPage,
  SpotsPage,
  UsersPage,
} from '../pages/SectionPages';
import { AppShell } from '../shell/AppShell';

export const routes: RouteObject[] = [
  {
    path: '/',
    Component: AppShell,
    children: [
      { index: true, element: <Navigate to="/review" replace /> },
      { path: 'review', Component: ReviewPage },
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
