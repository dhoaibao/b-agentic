type SharedState = {
  autoModeEnabled: boolean;
};

const STATE_KEY = Symbol.for("b-agentic.shared-state");
const globalState = globalThis as typeof globalThis & {
  [key: symbol]: SharedState | undefined;
};
const state = (globalState[STATE_KEY] ??= {
  autoModeEnabled: false,
});

export function isAutoModeEnabled(): boolean {
  return state.autoModeEnabled;
}
export function setAutoModeEnabled(enabled: boolean): void {
  state.autoModeEnabled = enabled;
}
