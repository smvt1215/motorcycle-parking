import { render } from '@testing-library/react';
import { Provider } from 'react-redux';
import { createMemoryRouter, RouterProvider } from 'react-router';
import { DataConnectionContext, type DataConnection } from '../app/connection';
import { routes } from '../app/routes';
import { makeStore } from '../app/store';
import type { AdminDataSource } from '../review/source';

/** The whole admin at `path`, with an optional data source. */
export function renderApp(
  path: string,
  options: { source?: AdminDataSource; connection?: DataConnection } = {},
) {
  const store = makeStore({ source: options.source ?? null });
  const router = createMemoryRouter(routes, { initialEntries: [path] });
  const connection = options.connection ?? (options.source ? 'fixture' : 'none');
  render(
    <DataConnectionContext.Provider value={connection}>
      <Provider store={store}>
        <RouterProvider router={router} />
      </Provider>
    </DataConnectionContext.Provider>,
  );
  return { store, router };
}
