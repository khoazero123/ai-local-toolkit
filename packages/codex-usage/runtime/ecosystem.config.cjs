const path = require("node:path");
const os = require("node:os");

const TOOL_DIR = __dirname;
const CODEX_HOME = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const ENV = {
  CODEX_HOME,
  CODEX_USAGE_TOOL_DIR: TOOL_DIR,
  CODEX_RESET_WATCH_CONFIG: path.join(TOOL_DIR, "codex-reset-watch.config.json"),
  CODEX_RESET_WATCH_STATE: path.join(TOOL_DIR, "codex-reset-watch-state.json"),
  CODEX_RESET_WATCH_LOG: path.join(TOOL_DIR, "codex-reset-watch.log"),
};

module.exports = {
  apps: [
    {
      name: "codex-reset-watch",
      script: path.join(TOOL_DIR, "codex-reset-watch.mjs"),
      cwd: TOOL_DIR,
      interpreter: "node",
      autorestart: true,
      max_restarts: 10,
      restart_delay: 5000,
      windowsHide: true,
      env: ENV,
    },
  ],
};
