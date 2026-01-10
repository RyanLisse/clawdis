---
description: Update Clawdbot from upstream and rebuild macOS app
---

This workflow updates the local repository from `upstream/main`, resolves dependencies, and rebuilds the project including the macOS application.

1. Fetch latest changes from upstream
   ```bash
   git fetch upstream
   ```

2. Merge upstream changes into local main branch
   ```bash
   git merge upstream/main
   ```
   > [!NOTE] 
   > If merge conflicts occur, you will need to resolve them manually before proceeding.

3. Install dependencies
   ```bash
   pnpm install
   ```
   > [!TIP]
   > If `@buape/carbon` patch fails, verify it is disabled in `package.json`.

4. Build backend and UI
   // turbo
   ```bash
   pnpm build && pnpm ui:build
   ```

5. Rebuild macOS application
   // turbo
   ```bash
   pnpm mac:package
   ```

6. Verify configuration and health
   ```bash
   pnpm clawdbot doctor && pnpm clawdbot health
   ```
restart-mac.sh