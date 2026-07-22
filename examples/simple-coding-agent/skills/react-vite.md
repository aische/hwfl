---
name: skills/react-vite
skill:
  kind: instruction
  summary: "Minimal Vite React+TypeScript app layout and verify commands"
  tags: [react, typescript, vite, npm]
---

# React / Vite / TypeScript

Prefer a **hand-written minimal tree** over `npm create vite` when the goal is
a tiny Hello page that builds (avoids interactive scaffolding and network).

Suggested files:

- `package.json` — `react`, `react-dom`, `vite`, `@vitejs/plugin-react`,
  `typescript`; scripts: `"dev"`, `"build"`, `"preview"`
- `vite.config.ts` — `@vitejs/plugin-react`
- `tsconfig.json` / `tsconfig.app.json` — strict enough for Vite
- `index.html` — mounts `#root`
- `src/main.tsx`, `src/App.tsx` — Hello page

Verify:

```bash
npm install
npm run build
```

If the prompt allows tests, a single Vitest or `npm run build` as the gate is
enough. Prefer build-only when network/time is tight.

Rules:

- Stay workspace-relative; never write outside the workspace.
- Prefer TypeScript over plain JS unless the prompt says otherwise.
- On TypeScript errors, fix with fs_edit and re-run `npm run build`.
