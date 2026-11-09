import { Navigate, type RouteObject } from 'react-router';
import { MoreLinks } from '../shell/MoreLinks';
import { AppShell } from '../shell/AppShell';
import { pendingRoute } from '../pending/routes';

/**
 * The deployed site: only 待處理 is React so far. Hosting sends /pending and
 * everything under it here; every other section is the Flutter admin, which
 * the navigation reaches with full page loads.
 */
export const liveRoutes: RouteObject[] = [
  {
    path: '/',
    Component: AppShell,
    children: [
      pendingRoute,
      { path: 'pending/more', Component: MoreLinks },
      { path: '*', element: <Navigate to="/pending" replace /> },
    ],
  },
];
