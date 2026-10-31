import js from '@eslint/js';
import reactHooks from 'eslint-plugin-react-hooks';
import globals from 'globals';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  { ignores: ['dist', 'dist-fixture', 'node_modules', 'artifacts'] },
  {
    files: ['**/*.{ts,tsx}'],
    extends: [js.configs.recommended, ...tseslint.configs.recommended, reactHooks.configs.flat.recommended],
    languageOptions: { ecmaVersion: 2023, globals: globals.browser },
  },
  {
    files: ['**/*.{js,mjs}'],
    extends: [js.configs.recommended],
    // scripts/smoke.mjs runs page.evaluate callbacks in the browser.
    languageOptions: { globals: { ...globals.node, ...globals.browser } },
  },
);
