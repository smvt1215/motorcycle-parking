import { Navigate, type RouteObject } from 'react-router';
import { AccountDeletion } from './pages/AccountDeletion';
import { NotFound } from './pages/NotFound';
import { PolicyPage } from './pages/Policy';
import { privacy } from './legal/policies';

/** The public site's paths (PM_ANS_20261101_124): more join as their pages land. */
export const routes: RouteObject[] = [
  { path: '/', element: <Navigate to="/account-deletion" replace /> },
  { path: '/account-deletion', element: <AccountDeletion /> },
  { path: '/privacy', element: <PolicyPage policy={privacy} /> },
  { path: '*', element: <NotFound /> },
];
