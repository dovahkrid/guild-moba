// Node ESM host for the dart2wasm output (replay_harness.wasm + .mjs loader).
import { readFileSync } from 'node:fs';
import { compile, instantiate, invoke } from './build/replay_harness.mjs';

const bytes = readFileSync(new URL('./build/replay_harness.wasm', import.meta.url));
invoke(await instantiate(await compile(bytes), {}));
