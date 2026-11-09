import type { RouteObject } from 'react-router';
import { AccountDeletion } from './pages/AccountDeletion';
import { Home } from './pages/Home';
import { NotFound } from './pages/NotFound';
import { Roadmap } from './pages/Roadmap';
import { CasePage } from './support/CasePage';
import { CancelPage, VerifyPage } from './support/LinkPages';
import { SupportPage } from './support/SupportPage';
import { PolicyPage } from './pages/Policy';
import { privacy, terms } from './legal/policies';

/** The public site's paths (PM_ANS_20261101_124): more join as their pages land. */
export const routes: RouteObject[] = [
  { path: '/', element: <Home /> },
  { path: '/roadmap', element: <Roadmap /> },
  { path: '/account-deletion', element: <AccountDeletion /> },
  { path: '/support', element: <SupportPage /> },
  { path: '/support/verify', element: <VerifyPage /> },
  { path: '/support/cancel', element: <CancelPage /> },
  { path: '/support/case', element: <CasePage /> },
  { path: '/privacy', element: <PolicyPage policy={privacy} /> },
  { path: '/terms', element: <PolicyPage policy={terms} /> },
  { path: '*', element: <NotFound /> },
];
