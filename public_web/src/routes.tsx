import { Navigate, type RouteObject } from 'react-router';
import { AccountDeletion } from './pages/AccountDeletion';
import { NotFound } from './pages/NotFound';
import { CancelPage, VerifyPage } from './support/LinkPages';
import { SupportPage } from './support/SupportPage';

/** The public site's paths (PM_ANS_20261101_124): more join as their pages land. */
export const routes: RouteObject[] = [
  { path: '/', element: <Navigate to="/account-deletion" replace /> },
  { path: '/account-deletion', element: <AccountDeletion /> },
  { path: '/support', element: <SupportPage /> },
  { path: '/support/verify', element: <VerifyPage /> },
  { path: '/support/cancel', element: <CancelPage /> },
  { path: '*', element: <NotFound /> },
];
