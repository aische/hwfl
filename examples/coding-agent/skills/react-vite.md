---
name: skills/react-vite
skill:
  kind: instruction
  summary: "Vite React+TypeScript scaffold, npm install, and build verify"
  tags: [react, typescript, vite, npm]
---

# React / Vite / TypeScript

Hand-write a **complete minimal tree** in the workspace root (no nested app
folder unless the user asks). Do **not** use interactive `npm create vite`.
Always install deps before build.

## Required files

### `package.json`

Use this shape (adjust `name` / title only if needed):

```json
{
  "name": "app",
  "private": true,
  "version": "0.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc && vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@types/react": "^18.3.12",
    "@types/react-dom": "^18.3.1",
    "@vitejs/plugin-react": "^4.3.4",
    "typescript": "~5.6.3",
    "vite": "^5.4.11"
  }
}
```

### `tsconfig.json`

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "useDefineForClassFields": true,
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "skipLibCheck": true,
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "isolatedModules": true,
    "moduleDetection": "force",
    "noEmit": true,
    "jsx": "react-jsx",
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true
  },
  "include": ["src"]
}
```

Note: `"noEmit": true` with `"build": "tsc && vite build"` — if `tsc` errors
on noEmit, use `"build": "vite build"` only, or set `"noEmit": false` and
`"outDir": "dist-types"`. Simplest reliable gate: `"build": "vite build"`
after a clean `tsc --noEmit` via `npx tsc --noEmit` when debugging. Default
prefer `"build": "vite build"` for demos so install+build is the gate.

**Recommended scripts for this agent:**

```json
"scripts": {
  "dev": "vite",
  "build": "vite build",
  "preview": "vite preview"
}
```

### `vite.config.ts`

```ts
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
})
```

### `index.html`

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>App</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
```

### `src/vite-env.d.ts`

```ts
/// <reference types="vite/client" />
```

### `src/main.tsx`, `src/App.tsx`, CSS

Mount `App` under `#root` with `React.StrictMode`. Implement the user’s UI
fully in TypeScript (e.g. canvas drawing, color/brush, clear, PNG export) —
no stub components, no missing imports.

## Verify (required order)

```bash
npm install
npm run build
```

Plan these as separate tasks or one scaffold task that installs then a final
build task. **Never** run `npm run build` before a successful `npm install`.

Rules:

- Always `npm install` after writing/updating `package.json`.
- Stay workspace-relative; never write outside the workspace.
- Prefer TypeScript. Fix Vite/TS errors with fs_edit / fs_patch and re-run.
- Write files with fs_write — do not tell the user to create them manually.
