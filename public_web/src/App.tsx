import { createBrowserRouter, Navigate, RouterProvider, type RouteObject } from 'react-router';
import { AccountDeletion } from './pages/AccountDeletion';
import { NotFound } from './pages/NotFound';

/** The public site's paths (PM_ANS_20261101_124): more join as their pages land. */
export const routes: RouteObject[] = [
  { path: '/', element: <Navigate to="/account-deletion" replace /> },
  { path: '/account-deletion', element: <AccountDeletion /> },
  { path: '*', element: <NotFound /> },
];

const router = createBrowserRouter(routes);

export function App() {
  return <RouterProvider router={router} />;
}
