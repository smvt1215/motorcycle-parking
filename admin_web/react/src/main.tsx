import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { createBrowserRouter, RouterProvider } from 'react-router';
import { routes } from './app/routes';
import { makeStore } from './app/store';
import './design/global.css';

const root = document.getElementById('root');
if (!root) throw new Error('#root is missing from index.html');

createRoot(root).render(
  <StrictMode>
    <Provider store={makeStore()}>
      <RouterProvider router={createBrowserRouter(routes)} />
    </Provider>
  </StrictMode>,
);
