import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { createBrowserRouter, RouterProvider } from 'react-router';
import { DataConnectionContext, type DataConnection } from './app/connection';
import { routes } from './app/routes';
import { makeStore } from './app/store';
import type { AdminDataSource } from './review/source';
import './design/global.css';

const root = document.getElementById('root');
if (!root) throw new Error('#root is missing from index.html');

// Only `vite --mode fixture` (.env.fixture) bundles the sample data; a
// production build replaces the condition with false and drops the import.
let source: AdminDataSource | null = null;
let connection: DataConnection = 'none';
if (import.meta.env.VITE_ADMIN_DATA === 'fixture') {
  const { fixtureSource } = await import('./review/fixtureSource');
  source = fixtureSource({ latencyMs: 400 });
  connection = 'fixture';
}

createRoot(root).render(
  <StrictMode>
    <DataConnectionContext.Provider value={connection}>
      <Provider store={makeStore({ source })}>
        <RouterProvider router={createBrowserRouter(routes)} />
      </Provider>
    </DataConnectionContext.Provider>
  </StrictMode>,
);
