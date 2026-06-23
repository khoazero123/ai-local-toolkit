const path = require("node:path");
const os = require("node:os");

const CODEX_HOME = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const ENV = {
  CODEX_HOME,
  CODEX_RESET_WATCH_CONFIG: path.join(CODEX_HOME, "codex-reset-watch.config.json"),
};

module.exports = {
  apps: [
    {
      name: "codex-reset-watch",
      script: path.join(CODEX_HOME, "codex-reset-watch.mjs"),
      cwd: CODEX_HOME,
      interpreter: "node",
      autorestart: true,
      max_restarts: 10,
      restart_delay: 5000,
      windowsHide: true,
      env: ENV,
    },
  ],
};
