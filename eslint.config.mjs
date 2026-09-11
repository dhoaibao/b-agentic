import eslint from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  {
    ignores: [
      "adapters/pi/extensions/b-agentic-support/mcp.ts",
      "adapters/pi/extensions/b-agentic-support/permissions-data.ts",
    ],
  },
  eslint.configs.recommended,
  ...tseslint.configs.recommended,
);
