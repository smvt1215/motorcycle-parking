import type { RouteObject } from 'react-router';
import { PendingCase } from './PendingCase';
import { PendingIndex, PendingPage } from './PendingPage';

/** Shared by the deployed page and the full fixture app. */
export const pendingRoute: RouteObject = {
  path: 'pending',
  Component: PendingPage,
  children: [
    { index: true, Component: PendingIndex },
    { path: ':caseId', Component: PendingCase },
  ],
};
