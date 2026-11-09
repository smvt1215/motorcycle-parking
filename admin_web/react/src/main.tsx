import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { setupListeners } from '@reduxjs/toolkit/query';
import { createBrowserRouter, RouterProvider, type RouteObject } from 'react-router';
import type { PostgrestConnection } from './api/v1/base';
import { DataConnectionContext, type DataConnection } from './app/connection';
import { makeStore } from './app/store';
import { AuthGate } from './auth/AuthGate';
import { AuthController } from './auth/controller';
import type { AdminAuthGateway } from './auth/gateway';
import type { AdminDataSource } from './review/source';
import './design/global.css';

const root = document.getElementById('root');
if (!root) throw new Error('#root is missing from index.html');

let source: AdminDataSource | null = null;
let postgrest: PostgrestConnection | null = null;
let gateway: AdminAuthGateway | null = null;
let connection: DataConnection = 'none';
let routes: RouteObject[];

// Only `vite --mode fixture` (.env.fixture) bundles the sample data; a
// production build replaces the condition with false and drops the imports.
if (import.meta.env.VITE_ADMIN_DATA === 'fixture') {
  const [{ fixtureSource }, fixture, full] = await Promise.all([
    import('./review/fixtureSource'),
    import('./pending/fixture'),
    import('./app/routes'),
  ]);
  source = fixtureSource({ latencyMs: 400 });
  gateway = fixture.fixtureGateway(window.location.search);
  postgrest = fixture.fixturePostgrest();
  connection = 'fixture';
  routes = full.routes;
} else {
  const [{ liveRoutes }, { supabaseGateway }] = await Promise.all([
    import('./app/liveRoutes'),
    import('./auth/supabaseGateway'),
  ]);
  routes = liveRoutes;
  const url = import.meta.env.VITE_SUPABASE_URL;
  const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;
  if (url && anonKey) {
    const live = supabaseGateway(url, anonKey, window.location.origin);
    gateway = live;
    postgrest = { url, anonKey, accessToken: () => live.accessToken() };
    connection = 'live';
  }
}

const store = makeStore({ source, postgrest });
setupListeners(store.dispatch);
const controller = new AuthController(gateway);

createRoot(root).render(
  <StrictMode>
    <DataConnectionContext.Provider value={connection}>
      <Provider store={store}>
        <AuthGate controller={controller}>
          <RouterProvider router={createBrowserRouter(routes)} />
        </AuthGate>
      </Provider>
    </DataConnectionContext.Provider>
  </StrictMode>,
);
